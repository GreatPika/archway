'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {parseJson, validateRequest, portablePath} = require('./framing.cjs');
const {trace} = require('./trace.cjs');
const {packageOrigin} = require('./packages.cjs');
const {nodeOrigins} = require('./node-origin.cjs');
const TYPESCRIPT_VERSION = '5.9.3';
const REQUEST_LIMIT = 8 * 1048576;

function diagnostic(code, message, source = null, range = null) {
  return {code, message, path: source, source_range: range};
}
function point(source, offset) {
  const position = source.getLineAndCharacterOfPosition(offset);
  return {line: position.line + 1, column: position.character + 1};
}
function span(source, name, start, end) {
  return {path: name, start: point(source, start), end: point(source, end)};
}
function decoded(bytes) {
  if (bytes[0] === 0xff && bytes[1] === 0xfe) return bytes.toString('utf16le', 2);
  if (bytes[0] === 0xfe && bytes[1] === 0xff) {
    const copy = Buffer.from(bytes.subarray(2, bytes.length - bytes.length % 2));
    copy.swap16();
    return copy.toString('utf16le');
  }
  return new TextDecoder('utf-8', {fatal: true}).decode(bytes);
}

function inspect(request, root) {
  const response = {
    protocol_version: 2, request_id: request.request_id, project_id: request.project_id,
    status: 'failed', files: request.expected_files.map(file => ({path: file, membership: 'unknown', coverage: 'failed', input_id: null})),
    facts: [], unknowns: [], tool_errors: [], inputs: [],
  };
  try {
    trace(response, evidence => {
      let ts;
      try { ts = require(path.join(__dirname, 'vendor/typescript/lib/typescript.js')); }
      catch (error) {
        response.tool_errors.push(diagnostic('TYPESCRIPT_LOAD_FAILED', `Bundled TypeScript could not be loaded: ${error.message}`));
        return;
      }
      if (ts.version !== TYPESCRIPT_VERSION) {
        response.tool_errors.push(diagnostic('TYPESCRIPT_VERSION_MISMATCH', `Loaded TypeScript ${String(ts.version)}; expected ${TYPESCRIPT_VERSION}.`));
        return;
      }
      if (process.versions.node !== '24.21.0') {
        response.tool_errors.push(diagnostic('NODE_VERSION_MISMATCH', `Node ${process.versions.node}; expected 24.21.0.`));
        return;
      }
      const rootInput = evidence.observe(root);
      if (rootInput.kind !== 'directory' || rootInput.canonical_uri !== request.root_uri) throw Error('Repository root is not canonical');
      process.chdir(root);
      const config = path.join(root, ...request.config_path.split('/'));
      const parsed = ts.getParsedCommandLineOfConfigFile(config, {}, {
        ...ts.sys,
        onUnRecoverableConfigFileDiagnostic: issue => { throw Error(ts.flattenDiagnosticMessageText(issue.messageText, '\n')); },
      });
      if (!parsed) throw Error('TypeScript configuration could not be parsed');
      for (const issue of parsed.errors) response.tool_errors.push(diagnostic('TYPESCRIPT_CONFIG_ERROR', ts.flattenDiagnosticMessageText(issue.messageText, '\n'), request.config_path));
      if (parsed.options.allowJs || parsed.options.noResolve || parsed.options.plugins?.length) {
        response.tool_errors.push(diagnostic('UNSUPPORTED_ANALYSIS_CONFIGURATION', 'This helper slice does not support allowJs, noResolve, or compiler plugins.', request.config_path));
      }
      const host = ts.createCompilerHost(parsed.options, true);
      host.trace = message => process.stderr.write(message + '\n');
      host.writeFile = () => { throw Error('Compiler writes are forbidden'); };
      const program = ts.createProgram({rootNames: parsed.fileNames, options: parsed.options, projectReferences: parsed.projectReferences, host});
      for (const issue of program.getOptionsDiagnostics()) response.tool_errors.push(diagnostic('TYPESCRIPT_CONFIG_ERROR', ts.flattenDiagnosticMessageText(issue.messageText, '\n'), request.config_path));
      const checker = program.getTypeChecker();
      const nodeOrigin = nodeOrigins({ts, checker, program, evidence, config, decoded});
      const sources = new Map(program.getSourceFiles().map(source => [path.resolve(source.fileName), source]));
      for (const row of response.files) {
        const filename = path.join(root, ...row.path.split('/'));
        const source = sources.get(filename);
        if (!source) { row.membership = 'nonmember'; row.coverage = 'not_applicable'; continue; }
        row.membership = 'member';
        const read = evidence.reads.get(filename);
        try {
          if (!read || read.input.canonical_uri !== pathToFileURL(filename).href || decoded(read.bytes) !== source.text) {
            throw Error('Source bytes or physical source identity could not be verified');
          }
        } catch (error) {
          response.unknowns.push(diagnostic('TYPESCRIPT_SOURCE_UNVERIFIED', error.message, row.path));
          continue;
        }
        row.coverage = 'complete'; row.input_id = read.input.id;
        function unknown(code, message, node) {
          row.coverage = 'partial';
          response.unknowns.push(diagnostic(code, message, row.path, node ? span(source, row.path, node.getStart(source), node.end) : null));
        }
        for (const issue of program.getSyntacticDiagnostics(source)) {
          row.coverage = 'partial';
          response.unknowns.push(diagnostic('TYPESCRIPT_SYNTAX_ERROR', ts.flattenDiagnosticMessageText(issue.messageText, '\n'), row.path,
            issue.start === undefined ? null : span(source, row.path, issue.start, issue.start + (issue.length || 0))));
        }
        for (const reference of [...source.referencedFiles, ...source.typeReferenceDirectives, ...source.libReferenceDirectives]) {
          row.coverage = 'partial';
          response.unknowns.push(diagnostic('UNSUPPORTED_MODULE_REFERENCE', 'Triple-slash references are not represented by helper protocol v1.', row.path, span(source, row.path, reference.pos, reference.end)));
        }
        function moduleFact(node, literal, kind, typeOnly) {
          const bindingIds = kind === 'require' ? nodeOrigin.requireBinding(node.expression, source) : [];
          if (bindingIds === null) {
            unknown('UNSUPPORTED_MODULE_REFERENCE', 'Bound require identifier is not a proven CommonJS module loader.', node);
            return;
          }
          if (!literal || !ts.isStringLiteralLike(literal)) { unknown('UNSUPPORTED_MODULE_REFERENCE', 'Reference does not have a supported literal module string.', node); return; }
          const hasMode = node.attributes?.elements.some(attribute => attribute.name.text === 'resolution-mode');
          const modeAllowed = ts.isImportTypeNode(node) || ts.isExclusivelyTypeOnlyImportOrExport(node);
          if (hasMode && !modeAllowed || typeOnly && node.attributes && !ts.getResolutionModeOverride(node.attributes)) {
            unknown('UNSUPPORTED_MODULE_REFERENCE', 'Reference has invalid resolution-mode attributes.', node);
            return;
          }
          const fact = {source: row.path, source_range: span(source, row.path, node.getStart(source), node.end), kind,
            specifier: literal.text, type_only: !!typeOnly, resolution: {kind: 'unresolved'}, input_ids: [...new Set([read.input.id, ...bindingIds])]};
          const builtin = nodeOrigin.builtin(literal, kind, source);
          if (builtin) {
            fact.resolution = {kind: 'builtin', identity: builtin.identity};
            fact.input_ids = [...new Set([...fact.input_ids, ...builtin.ids])];
            response.facts.push(fact);
            return;
          }
          let resolution, targets;
          if (kind === 'require') {
            // TS does not collect require calls in TS source. Resolve the occurrence
            // in require mode, but never invent Program membership or a source redirect.
            resolution = ts.resolveModuleName(literal.text, source.fileName,
              program.getCompilerOptionsForFile(source), host, undefined, undefined,
              ts.ModuleKind.CommonJS).resolvedModule;
            const target = resolution && program.getSourceFile(resolution.resolvedFileName);
            targets = target ? [target] : [];
          } else {
            resolution = program.getResolvedModuleFromModuleSpecifier(literal, source)?.resolvedModule;
            const symbol = checker.getSymbolAtLocation(literal);
            // The module-string symbol points to the direct file; imported binding aliases do not.
            targets = (symbol?.declarations || []).filter(ts.isSourceFile);
          }
          if (targets.length !== 1) {
            unknown('UNRESOLVED_IMPORT', 'The Program did not establish one physical direct module target.', node);
          } else {
            const target = targets[0];
            const targetRead = evidence.reads.get(path.resolve(target.fileName));
            const candidate = path.resolve(target.fileName);
            const options = program.getCompilerOptionsForFile(source);
            const configuredPath = Object.keys(options.paths || {}).some(pattern => {
              const star = pattern.indexOf('*');
              return star < 0 ? literal.text === pattern :
                literal.text.length >= pattern.length - 1 && literal.text.startsWith(pattern.slice(0, star)) &&
                literal.text.endsWith(pattern.slice(star + 1));
            });
            const localReference = /^(?:\.\.?\/)/.test(literal.text) ||
              (resolution && !resolution.isExternalLibraryImport && (options.baseUrl || configuredPath));
            let origin;
            try { origin = packageOrigin(evidence, config, target, resolution, source.fileName, literal.text, ts); } catch (_) { origin = null; }
            if (origin && targetRead && decoded(targetRead.bytes) === target.text) {
              if (origin.kind === 'local') {
                const relative = path.relative(root, candidate).split(path.sep).join('/');
                const inside = relative !== '..' && !relative.startsWith('../') && !path.isAbsolute(relative);
                if (inside && !portablePath(relative)) throw Error('Nonportable package target');
                fact.resolution = {kind: 'local', path: inside ? relative : null,
                  canonical_file_uri: targetRead.input.canonical_uri, via_path: null};
              } else fact.resolution = {kind: origin.kind, identity: origin.identity};
              fact.input_ids = [...new Set([read.input.id, targetRead.input.id, ...bindingIds, ...origin.ids])];
            } else if (!localReference || resolution?.packageId || [candidate, resolution?.originalPath, resolution?.resolvedFileName].some(file => file && file.split(path.sep).includes('node_modules')) ||
                !targetRead || targetRead.input.canonical_uri !== pathToFileURL(candidate).href) {
              unknown('UNSUPPORTED_TARGET_ORIGIN', 'The target requires package or alias provenance not implemented by this helper slice.', node);
            } else if (decoded(targetRead.bytes) !== target.text) {
              unknown('TYPESCRIPT_TARGET_UNVERIFIED', 'Target bytes differ from the Program source.', node);
            } else {
              const relative = path.relative(root, candidate).split(path.sep).join('/');
              const inside = relative !== '..' && !relative.startsWith('../') && !path.isAbsolute(relative);
              if (inside && !portablePath(relative)) {
                unknown('TYPESCRIPT_TARGET_UNVERIFIED', 'Target path is outside the portable path profile.', node);
              } else {
                fact.resolution = {kind: 'local', path: inside ? relative : null, canonical_file_uri: targetRead.input.canonical_uri, via_path: null};
                fact.input_ids = [...new Set([read.input.id, targetRead.input.id, ...bindingIds])];
              }
            }
          }
          response.facts.push(fact);
        }
        function referenceExpression(node) {
          while (ts.isParenthesizedExpression(node) || ts.isNonNullExpression(node) ||
              ts.isAsExpression(node) || ts.isTypeAssertionExpression(node) || ts.isSatisfiesExpression(node)) {
            node = node.expression;
          }
          return node;
        }
        function visit(node) {
          const reference = ts.isCallExpression(node) ? referenceExpression(node.expression) : null;
          if (ts.isImportDeclaration(node)) {
            const clause = node.importClause;
            const bindings = clause?.namedBindings;
            const typeOnly = clause?.isTypeOnly || (!clause?.name && bindings && ts.isNamedImports(bindings) &&
              bindings.elements.length > 0 && bindings.elements.every(binding => binding.isTypeOnly));
            moduleFact(node, node.moduleSpecifier, 'import', typeOnly);
          } else if (ts.isExportDeclaration(node) && node.moduleSpecifier) {
            const bindings = node.exportClause;
            const typeOnly = node.isTypeOnly || (bindings && ts.isNamedExports(bindings) &&
              bindings.elements.length > 0 && bindings.elements.every(binding => binding.isTypeOnly));
            moduleFact(node, node.moduleSpecifier, 'export', typeOnly);
          } else if (ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference)) {
            moduleFact(node, node.moduleReference.expression, 'import', node.isTypeOnly);
          } else if (ts.isImportTypeNode(node)) {
            moduleFact(node, ts.isLiteralTypeNode(node.argument) ? node.argument.literal : node.argument, 'import_type', true);
          } else if (ts.isCallExpression(node) && node.expression.kind === ts.SyntaxKind.ImportKeyword) {
            moduleFact(node, node.arguments[0], 'dynamic_import', false);
          } else if (ts.isCallExpression(node) && ts.isIdentifier(node.expression) && node.expression.text === 'require' && node.arguments.length === 1) {
            moduleFact(node, node.arguments[0], 'require', false);
          } else if ((ts.isCallExpression(node) && ts.isIdentifier(reference) && reference.text === 'require') ||
              (ts.isModuleDeclaration(node) && ts.isStringLiteral(node.name) && ts.isExternalModuleAugmentation(node))) {
            unknown('UNSUPPORTED_MODULE_REFERENCE', 'This explicit module reference is not supported by this helper slice.', node);
          }
          ts.forEachChild(node, visit);
        }
        visit(source);
      }
      response.status = response.unknowns.length || response.tool_errors.length ? 'incomplete' : 'complete';
    });
  } catch (error) {
    response.status = 'failed';
    response.tool_errors.push(diagnostic('TYPESCRIPT_ANALYSIS_FAILED', String(error.message || error)));
  }
  // Trace errors can arise during the final operation and must prevent a clean result.
  if (response.status === 'complete' && response.tool_errors.length) response.status = 'incomplete';
  return response;
}

async function main() {
  const chunks = [];
  let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    if (size > REQUEST_LIMIT) throw Error('Helper request exceeds 8 MiB');
    chunks.push(chunk);
  }
  const bytes = Buffer.concat(chunks);
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) throw Error('JSON BOM is forbidden');
  const request = parseJson(new TextDecoder('utf-8', {fatal: true}).decode(bytes));
  const root = validateRequest(request);
  const response = inspect(request, root);
  process.stdout.write(JSON.stringify(response) + '\n');
}
main().catch(error => {
  process.stderr.write(`TypeScript helper: ${String(error.message || error)}\n`);
  process.exitCode = 1;
});
