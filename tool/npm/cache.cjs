'use strict';
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const {createHash, randomUUID} = require('node:crypto');
const {extractNativeArchive} = require('./archive.cjs');
const {limits, requireThat, digest, parseManifest} = require('./inventory.cjs');
const targets = ['linux-x64', 'macos-arm64', 'windows-x64'];

function selectedIdentity(descriptor, target) {
  const {version, source} = descriptor;
  requireThat(descriptor.schema_version === 1 && Object.keys(descriptor).length === 4 &&
    typeof version === 'string' && version.length <= 200 &&
    /^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.+-]+)?$/.test(version) &&
    source && Object.keys(source).sort().join(',') === 'commit,lockfile_sha256,tree' &&
    /^[a-f0-9]{40}$/.test(source.commit) && /^[a-f0-9]{40}$/.test(source.tree) &&
    source.lockfile_sha256 && Object.keys(source.lockfile_sha256).sort().join(',') ===
      'assets/typescript/package-lock.json,pubspec.lock' &&
    Object.values(source.lockfile_sha256).every(digest) && descriptor.targets &&
    Object.keys(descriptor.targets).length === 3 && targets.every(t => Object.hasOwn(descriptor.targets, t)),
  'Invalid embedded acquisition descriptor');
  requireThat(targets.includes(target), `Unsupported native target: ${target}`);
  const pin = descriptor.targets[target];
  requireThat(pin && Object.keys(pin).sort().join(',') === 'manifest_sha256,sha256,size,url' &&
    Number.isSafeInteger(pin.size) && pin.size > 0 && pin.size <= limits.archive &&
    digest(pin.sha256) && digest(pin.manifest_sha256), 'Invalid embedded archive identity');
  const url = new URL(pin.url);
  requireThat(url.protocol === 'https:' && url.hostname && !url.username && !url.password && !url.hash,
    'Native archive URL must use HTTPS');
  return {pin, identity: {version, source, target}};
}
async function exists(name) {
  try { await fsp.lstat(name); return true; } catch (error) {
    if (error.code === 'ENOENT') return false;
    throw error;
  }
}
async function ordinary(name, directory) {
  const stat = await fsp.lstat(name);
  requireThat((directory ? stat.isDirectory() : stat.isFile()) &&
    await fsp.realpath(name) === name, 'Aliased or nonordinary native cache entry');
  return stat;
}
async function prepare(directory) {
  requireThat(path.isAbsolute(directory) && path.normalize(directory) === directory,
    'Native cache path must be canonical');
  const missing = [];
  let current = directory;
  while (!await exists(current)) { missing.push(current); current = path.dirname(current); }
  await ordinary(current, true);
  for (const name of missing.reverse()) {
    try { await fsp.mkdir(name, {mode: 0o700}); } catch (error) {
      if (error.code !== 'EEXIST') throw error;
    }
    await ordinary(name, true);
  }
}
async function readFileIdentity(file, bound, collect = false) {
  requireThat((await ordinary(file, false)).size <= bound, 'Native cache file exceeds bound');
  const chunks = [], hash = createHash('sha256');
  let size = 0;
  for await (const chunk of fs.createReadStream(file)) {
    size += chunk.length;
    requireThat(size <= bound, 'Native cache file exceeds bound');
    hash.update(chunk);
    if (collect) chunks.push(chunk);
  }
  return {size, sha256: hash.digest('hex'), bytes: collect ? Buffer.concat(chunks) : null};
}

// Private fixture download seam; the installed launcher never supplies one.
async function acquireNative(descriptor, target, cache, download) {
  const {pin, identity} = selectedIdentity(descriptor, target);
  const parent = path.join(cache, identity.version, target);
  await prepare(parent);
  const key = path.join(parent, pin.sha256);
  async function warm() {
    const record = await readFileIdentity(key, 64, true);
    const name = record.bytes.toString('utf8');
    requireThat(/^\.archway-native-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\n$/.test(name),
      'Invalid native cache publication record');
    const root = path.join(parent, name.slice(0, -1));
    await ordinary(root, true);
    const manifest = await readFileIdentity(path.join(root, 'manifest.json'), limits.manifest, true);
    const files = parseManifest(manifest.bytes, pin, identity);
    const relative = `bin/${target}/archway${target === 'windows-x64' ? '.exe' : ''}`;
    const expected = files.get(relative);
    const executable = path.join(root, ...relative.split('/'));
    const actual = await readFileIdentity(executable, limits.file);
    requireThat(actual.size === expected.size && actual.sha256 === expected.sha256,
      'Native cached executable differs from pin');
    return executable;
  }
  if (await exists(key)) return warm();
  const workspace = await fsp.mkdtemp(path.join(parent, '.archway-download-'));
  const basename = `.archway-native-${randomUUID()}`;
  const extraction = path.join(parent, basename);
  const record = path.join(parent, `.archway-record-${randomUUID()}`);
  let extracted = false, recordOwned = false, committed = false;
  try {
    const archive = path.join(workspace, 'archive');
    const fetch = download ?? require('./download.cjs').downloadNativeArchive;
    await fetch(new URL(pin.url), archive, pin.size);
    await extractNativeArchive(archive, pin, identity, extraction);
    extracted = true;
    const recordHandle = await fsp.open(record, 'wx', 0o600);
    recordOwned = true;
    try { await recordHandle.writeFile(basename + '\n'); }
    finally { await recordHandle.close(); }
    try {
      // The record is the atomic no-replace commit. Native files remain ordinary
      // canonical files in the complete unique extraction; no directory rename.
      await fsp.link(record, key);
      committed = true;
    } catch (error) {
      if (error.code !== 'EEXIST') throw error;
      // A collision alone permits reuse, after full warm winner verification.
    }
    return await warm();
  } finally {
    try { if (recordOwned) await fsp.unlink(record); }
    finally {
      try { if (extracted && !committed) await fsp.rm(extraction, {recursive: true}); }
      finally { await fsp.rm(workspace, {recursive: true}); }
    }
  }
}
module.exports = {acquireNative};
