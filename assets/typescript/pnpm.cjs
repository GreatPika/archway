'use strict';
const path = require('node:path');
const {fileURLToPath, pathToFileURL} = require('node:url');
if (require('./vendor/yaml/package.json').version !== '2.8.1') throw Error('Bundled YAML version mismatch');
const yaml = require('./vendor/yaml/dist/index.js');
const {depPathToFilename} = require('./pnpm-path.cjs');
const {versionRequest} = require('./version-request.cjs');
const own = (object, key) => object && Object.hasOwn(object, key) ? object[key] : undefined;
function same(left, right) {
  if (left === right) return true;
  if (!left || !right || typeof left !== 'object' || typeof right !== 'object' ||
      Array.isArray(left) !== Array.isArray(right)) return false;
  const keys = Object.keys(left);
  return keys.length === Object.keys(right).length && keys.every(key => Object.hasOwn(right, key) && same(left[key], right[key]));
}
function workspaceMember(patterns, relative) {
  if (!Array.isArray(patterns) || !patterns.every(item => typeof item === 'string')) return false;
  let included = false;
  for (let pattern of patterns) {
    const excluded = pattern.startsWith('!');
    if (excluded) pattern = pattern.slice(1);
    pattern = pattern.replace(/^\.\//, '').replace(/\/$/, '');
    const expression = pattern.split('**').map(part => part.split('*')
      .map(text => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('[^/]*')).join('.*');
    if (new RegExp('^' + expression + '$').test(relative)) {
      if (excluded) return false;
      included = true;
    }
  }
  return included;
}
function parseYaml(text) {
  if (Buffer.byteLength(text) > 8 * 1048576) throw Error('Oversized package metadata');
  const doc = yaml.parseDocument(text, {schema: 'core', uniqueKeys: true, merge: false});
  if (doc.errors.length || doc.warnings.length) throw Error('Invalid package YAML');
  let count = 0;
  function data(value, depth = 0) {
    if (++count > 200000 || depth > 64) throw Error('Excessive package YAML');
    if (value instanceof Map) {
      const result = Object.create(null);
      for (const [key, item] of value) {
        if (typeof key !== 'string') throw Error('Non-string metadata key');
        result[key] = data(item, depth + 1);
      }
      return result;
    }
    if (Array.isArray(value)) return value.map(item => data(item, depth + 1));
    if (value === null || ['string', 'boolean', 'number'].includes(typeof value)) return value;
    throw Error('Unsupported metadata value');
  }
  return data(doc.toJS({mapAsMap: true, maxAliasCount: 20}));
}
function pnpmOrigin(context) {
  const {directory, install, manifest, rootInput, sourceFile, json, read, observe, observed, observedInput, ts} = context;
  const lock = read(path.join(directory, 'pnpm-lock.yaml'), parseYaml);
  const modules = read(path.join(directory, 'node_modules/.modules.yaml'), parseYaml);
  if (String(lock?.lockfileVersion) !== '9.0' || modules?.layoutVersion !== 5 ||
      modules.nodeLinker !== 'isolated' || modules.packageManager !== 'pnpm@9.15.9' ||
      typeof modules.virtualStoreDir !== 'string') return null;
  const store = path.resolve(directory, 'node_modules', modules.virtualStoreDir);
  const installed = read(path.join(store, 'lock.yaml'), parseYaml);
  if (String(installed?.lockfileVersion) !== '9.0') return null;
  let importer = path.dirname(sourceFile), importerManifest;
  for (;;) {
    importerManifest = json(path.join(importer, 'package.json'));
    if (importerManifest || importer === directory || path.dirname(importer) === importer) break;
    importer = path.dirname(importer);
  }
  const importerKey = path.relative(directory, importer).split(path.sep).join('/') || '.';
  const importRow = own(lock.importers, importerKey);
  const installedImport = own(installed.importers, importerKey);
  const name = install.slice(install.lastIndexOf(`${path.sep}node_modules${path.sep}`) + 14).split(path.sep).join('/');
  const dependency = value => own(value?.optionalDependencies, name) ?? own(value?.dependencies, name) ?? own(value?.devDependencies, name);
  const rootManifest = json(path.join(directory, 'package.json'));
  if (rootManifest?.packageManager && rootManifest.packageManager !== 'pnpm@9.15.9') return null;
  const overrides = rootManifest?.pnpm?.overrides || Object.create(null);
  if (!same(overrides, lock.overrides || Object.create(null)) ||
      !same(lock.overrides, installed.overrides)) return null;
  if (Object.keys(overrides).some(key => key.includes('>') || key !== name && key.startsWith(name + '@'))) return null;
  const effectiveSource = own(overrides, name) ?? dependency(importerManifest);
  if (!versionRequest(ts, effectiveSource, manifest)) return null;
  let ref = dependency(importRow), installedRef = dependency(installedImport);
  if (!importRow && importerManifest) {
    const sourceRoot = observe(importer).canonical_uri;
    const storeRoot = observe(store);
    if (storeRoot.kind !== 'directory') return null;
    const candidates = Object.keys(lock.snapshots || {}).filter(key =>
      key.startsWith(importerManifest.name + '@') && pathToFileURL(path.join(fileURLToPath(storeRoot.canonical_uri),
        depPathToFilename(key, modules.virtualStoreDirMaxLength ?? 120), 'node_modules', importerManifest.name)).href === sourceRoot);
    if (candidates.length !== 1) return null;
    const parentKey = candidates[0], parent = own(lock.snapshots, parentKey);
    const parentPackage = own(lock.packages, parentKey.split('(')[0]);
    if (!parentPackage || !same(parent, own(installed.snapshots, parentKey)) ||
        !same(parentPackage, own(installed.packages, parentKey.split('(')[0]))) return null;
    if (parentKey.split('(')[0] !== `${importerManifest.name}@${importerManifest.version}` &&
        parentPackage.version !== importerManifest.version) return null;
    const version = dependency(parent);
    if (typeof version !== 'string' || typeof effectiveSource !== 'string') return null;
    ref = {version, specifier: effectiveSource};
    installedRef = {version: dependency(own(installed.snapshots, parentKey)), specifier: effectiveSource};
  }
  if (!ref || typeof ref.version !== 'string' || ref.specifier !== effectiveSource ||
      !same(ref, installedRef)) return null;
  if (ref.version.startsWith('link:')) {
    const localRoot = path.resolve(importer, ref.version.slice(5));
    const local = json(path.join(localRoot, 'package.json'));
    if (observe(localRoot).canonical_uri !== rootInput.canonical_uri ||
        local?.name !== manifest.name || local?.version !== manifest.version) return null;
    if (ref.specifier.startsWith('workspace:')) {
      const workspace = read(path.join(directory, 'pnpm-workspace.yaml'), parseYaml);
      const rel = path.relative(directory, localRoot).split(path.sep).join('/');
      if (!workspaceMember(workspace?.packages, rel)) return null;
    } else if (!ref.specifier.startsWith('link:') || path.resolve(importer, ref.specifier.slice(5)) !== localRoot) return null;
    return {kind: 'local'};
  }
  const at = ref.version.indexOf('@'), colon = ref.version.indexOf(':'), peer = ref.version.indexOf('(');
  const named = ref.version.startsWith('@') || at >= 0 && (colon < 0 || at < colon) && (peer < 0 || at < peer);
  const snapshot = named ? ref.version : `${name}@${ref.version}`;
  const snapshotRow = own(lock.snapshots, snapshot);
  const packageKey = snapshot.split('(')[0];
  const pkg = own(lock.packages, packageKey);
  if (!snapshotRow || !pkg || !same(snapshotRow, own(installed.snapshots, snapshot)) ||
      !same(pkg, own(installed.packages, packageKey))) return null;

  const expected = path.join(store, depPathToFilename(snapshot, modules.virtualStoreDirMaxLength ?? 120), 'node_modules', manifest.name);
  if (observe(expected).canonical_uri !== rootInput.canonical_uri) return null;
  if (pkg.resolution?.type === 'directory' && typeof pkg.resolution.directory === 'string') {
    if (!ref.version.startsWith('file:') || packageKey !== `${manifest.name}@file:${pkg.resolution.directory}`) return null;
    const localRoot = path.resolve(directory, pkg.resolution.directory);
    if (observe(localRoot).kind !== 'directory') return null;
    const localManifest = json(path.join(localRoot, 'package.json'));
    const localFile = observe(path.join(localRoot, path.relative(install, observed)));
    if (localManifest?.name !== manifest.name || localManifest?.version !== manifest.version ||
        localFile.kind !== 'file' || localFile.sha256 !== observedInput.sha256) return null;
    if (ref.specifier.startsWith('workspace:')) {
      const workspace = read(path.join(directory, 'pnpm-workspace.yaml'), parseYaml);
      const rel = path.relative(directory, localRoot).split(path.sep).join('/');
      const member = workspaceMember(workspace?.packages, rel);
      const injected = own(modules.injectedDeps, rel);
      if (!member || importerManifest.dependenciesMeta?.[name]?.injected !== true ||
          importRow.dependenciesMeta?.[name]?.injected !== true || !Array.isArray(injected) ||
          !injected.some(route => typeof route === 'string' && observe(path.resolve(directory, route)).canonical_uri === rootInput.canonical_uri)) return null;
    } else if (ref.specifier !== `file:${pkg.resolution.directory}`) return null;
    return {kind: 'local'};
  }
  if (/^(?:file:|link:|workspace:)/.test(ref.specifier)) return null;
  const resolution = pkg.resolution;
  if (!resolution || typeof resolution !== 'object' || Array.isArray(resolution)) return null;
  const registryFields = Object.keys(resolution).every(key => ['integrity', 'tarball'].includes(key));
  if (resolution.type !== undefined && resolution.type !== 'git') return null;
  if (resolution.tarball !== undefined && (typeof resolution.tarball !== 'string' || !/^https?:\/\//.test(resolution.tarball))) return null;
  const registry = registryFields && packageKey === `${manifest.name}@${manifest.version}` && typeof pkg.resolution?.integrity === 'string';
  const tarball = registryFields && typeof pkg.resolution?.tarball === 'string' && /^https?:\/\//.test(pkg.resolution.tarball) &&
    pkg.version === manifest.version && packageKey === `${manifest.name}@${pkg.resolution.tarball}`;
  const git = Object.keys(resolution).every(key => ['type', 'repo', 'commit'].includes(key)) && typeof pkg.resolution?.repo === 'string' && /^(?:git\+)?(?:https?|ssh|git):\/\//.test(pkg.resolution.repo) &&
    typeof pkg.resolution.commit === 'string' && /^[0-9a-f]{40,64}$/i.test(pkg.resolution.commit) &&
    pkg.version === manifest.version && packageKey.startsWith(manifest.name + '@');
  if (!registry && !tarball && !git) return null;
  const source = ref.specifier;
  if (/^(?:git[+:]|ssh:|github:|gitlab:|bitbucket:)/.test(source)) {
    let url;
    try { url = new URL(source.replace(/^git\+/, '')); } catch (_) { return null; }
    if (!['https:', 'http:', 'ssh:', 'git:'].includes(url.protocol) || !url.hostname ||
        !/^#[0-9a-f]{40,64}$/i.test(url.hash)) return null;
    const commit = url.hash.slice(1).toLowerCase();
    const repository = url.pathname.replace(/\.git$/, '');
    if (git) {
      let resolved;
      try { resolved = new URL(resolution.repo.replace(/^git\+/, '')); } catch (_) { return null; }
      if (url.hostname !== resolved.hostname || repository !== resolved.pathname.replace(/\.git$/, '') ||
          commit !== resolution.commit.toLowerCase()) return null;
    } else if (!tarball || url.hostname !== 'github.com' ||
        resolution.tarball !== `https://codeload.github.com${repository}/tar.gz/${commit}`) return null;
  } else if (/^https?:\/\//.test(source)) {
    if (source !== resolution.tarball) {
      // pnpm normalizes the configured registry's canonical package tarball to
      // an integrity-only registry row. Other explicit URLs require exact joins.
      const scope = manifest.name.startsWith('@') ? manifest.name.split('/')[0] : 'default';
      const registryUrl = own(modules.registries, scope) ?? own(modules.registries, 'default');
      const basename = manifest.name.split('/').at(-1);
      if (!registry || Object.hasOwn(resolution, 'tarball') || typeof registryUrl !== 'string' || !/^https?:\/\//.test(registryUrl) ||
          source !== `${registryUrl.replace(/\/$/, '')}/${manifest.name}/-/${basename}-${manifest.version}.tgz`) return null;
    }
  } else if (!registry) return null;

  const suffix = snapshot.slice(packageKey.length);
  return {kind: 'external', identity: `pnpm:${manifest.name}@${manifest.version}${suffix}`};
}
module.exports = {parseYaml, pnpmOrigin, workspaceMember};
