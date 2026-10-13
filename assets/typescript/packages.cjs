'use strict';
const fs = require('node:fs');
const path = require('node:path');
const {pathToFileURL, fileURLToPath} = require('node:url');
const {parseJson} = require('./framing.cjs');
const {versionRequest} = require('./version-request.cjs');
const {pnpmOrigin, workspaceMember} = require('./pnpm.cjs');
const inside = (root, file) => file === root || file.startsWith(root + path.sep);
const own = (object, key) => object && Object.hasOwn(object, key) ? object[key] : undefined;
function remoteGit(value) {
  if (typeof value !== 'string') return null;
  try {
    const url = new URL(value.replace(/^git\+/, ''));
    if (!['https:', 'http:', 'ssh:', 'git:'].includes(url.protocol) || !url.hostname ||
        !/^#[0-9a-f]{40,64}$/i.test(url.hash)) return null;
    return `${url.hostname}${url.pathname.replace(/\.git$/, '')}${url.hash.toLowerCase()}`;
  } catch (_) { return null; }
}

// Metadata is data only. Every positive and negative read participates in the
// existing trace and is attached directly to the fact that used it.
function packageOrigin(evidence, config, target, resolution, sourceFile, specifier, ts) {
  const ids = new Set();
  function observe(file) { const input = evidence.observe(file); ids.add(input.id); return input; }
  function read(file, parser) {
    const input = observe(file);
    if (input.kind === 'absent') return null;
    if (input.kind !== 'file') throw Error('Package metadata is not a file');
    const value = parser(fs.readFileSync(file, 'utf8'));
    ids.add(evidence.reads.get(path.resolve(file)).input.id);
    return value;
  }
  const json = file => read(file, parseJson);
  function result(kind, manifest) { return {kind, identity: `npm:${manifest.name}@${manifest.version}`, ids: [...ids]}; }
  const finalFile = path.resolve(target.fileName);
  const observed = path.resolve(resolution?.originalPath || resolution?.resolvedFileName || finalFile);
  // A resolver lookup route must map to the final Program file, including its
  // prepared declaration redirect. Never search installed packages by name.
  const observedInput = observe(observed);
  if (observedInput.canonical_uri !== pathToFileURL(finalFile).href) return null;
  const parts = observed.split(path.sep);
  const index = parts.lastIndexOf('node_modules');
  if (index < 0 || !parts[index + 1]) {
    if (!resolution?.packageId || typeof specifier !== 'string') return null;
    let scope = path.dirname(sourceFile);
    for (;;) {
      const manifest = json(path.join(scope, 'package.json'));
      if (manifest) {
        const id = resolution.packageId;
        if (id.name !== manifest.name || id.version !== manifest.version ||
            !(specifier === manifest.name || specifier.startsWith(manifest.name + '/'))) return null;
        const subpath = specifier === manifest.name ? '.' : '.' + specifier.slice(manifest.name.length);
        let exported = manifest.exports, capture;
        if (exported && typeof exported === 'object' && Object.keys(exported).some(key => key.startsWith('.'))) {
          const exact = own(exported, subpath);
          if (exact !== undefined) exported = exact;
          else {
            const patterns = Object.keys(exported).filter(key => key.split('*').length === 2 &&
              subpath.startsWith(key.split('*')[0]) && subpath.endsWith(key.split('*')[1]));
            if (patterns.length !== 1) return null;
            const [before, after] = patterns[0].split('*');
            capture = subpath.slice(before.length, subpath.length - after.length);
            exported = exported[patterns[0]];
          }
        }
        function maps(value) {
          if (typeof value === 'string') return value.startsWith('./') && path.resolve(scope, capture === undefined ? value : value.replaceAll('*', capture)) === finalFile;
          if (value && typeof value === 'object') return Object.values(value).some(maps);
          return false;
        }
        if (!maps(exported) && !(subpath === '.' && [manifest.types, manifest.typings].some(value => typeof value === 'string' && maps(value.startsWith('./') ? value : './' + value)))) return null;
        observe(scope);
        return result('local', manifest);
      }
      if (path.dirname(scope) === scope) return null;
      scope = path.dirname(scope);
    }
  }
  const width = parts[index + 1].startsWith('@') ? 3 : 2;
  const install = parts.slice(0, index + width).join(path.sep);
  const manifest = json(path.join(install, 'package.json'));
  if (!manifest || typeof manifest.name !== 'string' || typeof manifest.version !== 'string') return null;
  const rootInput = observe(install);
  if (rootInput.kind !== 'directory' || !inside(fileURLToPath(rootInput.canonical_uri), finalFile)) return null;
  for (let directory = path.dirname(config);; directory = path.dirname(directory)) {
    const shrinkwrapFile = path.join(directory, 'npm-shrinkwrap.json');
    const hasShrinkwrap = observe(shrinkwrapFile).kind !== 'absent';
    const lock = json(hasShrinkwrap ? shrinkwrapFile : path.join(directory, 'package-lock.json'));
    if (hasShrinkwrap && (!lock || typeof lock !== 'object' || Array.isArray(lock))) return null;
    const pnpm = observe(path.join(directory, 'pnpm-lock.yaml'));
    if (lock || pnpm.kind !== 'absent') {
      if (pnpm.kind !== 'absent') {
        if (lock) return null;
        const origin = pnpmOrigin({directory, install, manifest, rootInput, sourceFile, json, read, observe, observed, observedInput, ts});
        return origin && {...origin, ids: [...ids]};
      }
      if (!lock || ![2, 3].includes(lock.lockfileVersion)) return null;
      const rootManifest = json(path.join(directory, 'package.json'));
      if (!rootManifest || rootManifest.packageManager && !rootManifest.packageManager.startsWith('npm@')) return null;
      const installedName = parts.slice(index + 1, index + width).join('/');
      // TypeScript uses forward slashes on Windows; containment uses native paths.
      let importer = path.dirname(path.resolve(sourceFile || config)), importerManifest;
      while (inside(directory, importer)) {
        importerManifest = json(path.join(importer, 'package.json'));
        if (importerManifest) break;
        if (importer === directory) break;
        importer = path.dirname(importer);
      }
      const dependency = value => own(value?.optionalDependencies, installedName) ??
        own(value?.dependencies, installedName) ?? own(value?.devDependencies, installedName);
      let source = dependency(importerManifest);
      const lockedImporter = own(lock.packages, path.relative(directory, importer).split(path.sep).join('/'));
      if (typeof source !== 'string' || dependency(lockedImporter) !== source) return null;
      let sourceBase = importer;
      const overrides = rootManifest.overrides;
      function relevant(value, depth = 0) {
        if (!value || typeof value !== 'object') return false;
        return Object.entries(value).some(([key, item]) => {
          const at = key.lastIndexOf('@');
          const name = at > 0 ? key.slice(0, at) : key;
          return [installedName, manifest.name].includes(name) || relevant(item, depth + 1);
        });
      }
      if (relevant(overrides)) {
        let override = own(overrides, installedName) ?? own(overrides, manifest.name);
        if (override && typeof override === 'object') override = own(override, '.');
        if (typeof override !== 'string') return null;
        const referenced = override.startsWith('$');
        const direct = dependency(rootManifest);
        if (referenced) override = own(rootManifest.devDependencies, override.slice(1)) ??
          own(rootManifest.optionalDependencies, override.slice(1)) ?? own(rootManifest.dependencies, override.slice(1));
        if (typeof override !== 'string' || direct !== undefined && override !== direct) return null;
        source = override;
        sourceBase = directory;
      }
      if (!versionRequest(ts, source, manifest)) return null;
      const key = path.relative(directory, install).split(path.sep).join('/');
      const row = own(lock.packages, key);
      if (!row) return null;
      if (row.link === true) {
        if (typeof row.resolved !== 'string') return null;
        const sourceRoot = path.resolve(directory, row.resolved);
        if (/^(?:file:|link:)/.test(source)) {
          if (observe(path.resolve(sourceBase, source.slice(5))).canonical_uri !== rootInput.canonical_uri) return null;
        } else {
          const workspaces = Array.isArray(rootManifest.workspaces) ? rootManifest.workspaces : rootManifest.workspaces?.packages;
          if (!workspaceMember(workspaces, path.relative(directory, sourceRoot).split(path.sep).join('/'))) return null;
        }
        const sourceInput = observe(sourceRoot);
        const sourceManifest = json(path.join(sourceRoot, 'package.json'));
        const lockedSource = own(lock.packages, row.resolved);
        if (sourceInput.canonical_uri !== rootInput.canonical_uri ||
            sourceManifest?.name !== manifest.name || sourceManifest?.version !== manifest.version ||
            lockedSource?.version !== manifest.version ||
            lockedSource.name && lockedSource.name !== manifest.name) return null;
        return result('local', manifest);
      }
      if (row.version !== manifest.version || row.name && row.name !== manifest.name) return null;
      if (installedName !== manifest.name && row.name !== manifest.name) return null;
      if (typeof row.resolved !== 'string') return null;
      if (row.resolved.startsWith('file:')) {
        if (!source.startsWith('file:')) return null;
        const effectiveRoot = observe(path.resolve(sourceBase, source.slice(5)));
        const sourceRoot = path.resolve(directory, row.resolved.slice(5));
        const sourceInput = observe(sourceRoot);
        if (sourceInput.kind !== 'directory' || sourceInput.canonical_uri !== effectiveRoot.canonical_uri) return null;
        const sourceManifest = json(path.join(sourceRoot, 'package.json'));
        const sourceFile = path.join(sourceRoot, path.relative(install, observed));
        const copied = observe(sourceFile);
        if (sourceManifest?.name !== manifest.name || sourceManifest?.version !== manifest.version ||
            copied.kind !== 'file' || copied.sha256 !== observedInput.sha256) return null;
        return result('local', manifest);
      }
      if (/^(?:file:|link:|workspace:)/.test(source)) return null;
      if (source.startsWith('npm:')) {
        const alias = /^(@[^/]+\/[^@]+|[^@]+)(?:@.+)?$/.exec(source.slice(4));
        if (!alias || alias[1] !== manifest.name) return null;
      }
      if (/^(?:git[+:]|ssh:|github:|gitlab:|bitbucket:)/.test(source) &&
          (!remoteGit(source) || remoteGit(source) !== remoteGit(row.resolved))) return null;
      if (/^https?:\/\//.test(source) && source !== row.resolved) return null;
      if (!/^https?:\/\//.test(row.resolved) &&
          !(remoteGit(row.resolved) && remoteGit(row.resolved) === remoteGit(source))) return null;
      return result('external', manifest);
    }
    if (path.dirname(directory) === directory) return null;
  }
}
module.exports = {packageOrigin};
