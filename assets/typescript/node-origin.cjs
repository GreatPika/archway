'use strict';
const path = require('node:path');
const {pathToFileURL} = require('node:url');
const {packageOrigin} = require('./packages.cjs');
const {isBuiltin} = require('node:module');
function nodeOrigins({ts, checker, program, evidence, config, decoded}) {
  function declarations(items, source) {
    if (!items?.length) return null;
    const ids = new Set();
    for (const declaration of items) {
      const file = declaration.getSourceFile();
      const filename = path.resolve(file.fileName);
      const read = evidence.reads.get(filename);
      if (!file.isDeclarationFile || program.getSourceFile(file.fileName) !== file ||
          !read || read.input.canonical_uri !== pathToFileURL(filename).href || decoded(read.bytes) !== file.text) return null;
      let origin;
      try { origin = packageOrigin(evidence, config, file, {resolvedFileName: filename}, source.fileName, undefined, ts); }
      catch (_) { return null; }
      if (origin?.kind !== 'external' || !/^(?:npm|pnpm):@types\/node@[^/]+$/.test(origin.identity)) return null;
      ids.add(read.input.id);
      origin.ids.forEach(id => ids.add(id));
    }
    return [...ids];
  }
  function requireBinding(expression, source) {
    const symbol = checker.getSymbolAtLocation(expression);
    if (!symbol) return [];
    if (!symbol.declarations?.every(node => ts.isVariableDeclaration(node) && node.name.getText() === 'require')) return null;
    const type = checker.getTypeAtLocation(expression);
    const signatures = type.getCallSignatures();
    if (!signatures.length) return null;
    return declarations([...symbol.declarations, ...(type.symbol?.declarations || []),
      ...signatures.map(signature => signature.declaration).filter(Boolean)], source);
  }
  function builtin(literal, kind, source) {
    if (process.versions.node !== '24.21.0' || !isBuiltin(literal.text)) return null;
    const symbol = checker.getSymbolAtLocation(literal) || (kind === 'require' &&
      checker.getAmbientModules().find(item => item.name === JSON.stringify(literal.text)));
    if (!symbol?.declarations?.every(node => ts.isModuleDeclaration(node) &&
        ts.isStringLiteral(node.name) && node.name.text === literal.text)) return null;
    const ids = declarations(symbol.declarations, source);
    return ids && {identity: literal.text.startsWith('node:') ? literal.text : `node:${literal.text}`, ids};
  }
  return {requireBinding, builtin};
}
module.exports = {nodeOrigins};
