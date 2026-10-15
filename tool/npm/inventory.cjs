'use strict';
const {createHash} = require('node:crypto');
const {isDeepStrictEqual} = require('node:util');
const limits = Object.freeze({archive: 512 * 1024 * 1024, file: 128 * 1024 * 1024,
  manifest: 2 * 1024 * 1024, entries: 4096});
function requireThat(ok, reason) { if (!ok) throw new Error(reason); }
function digest(value) { return typeof value === 'string' && /^[a-f0-9]{64}$/.test(value); }
function pathKey(name) {
  return name.normalize('NFC').toLowerCase().toUpperCase().toLowerCase().normalize('NFC');
}
function inventory() {
  const files = new Map(), aliases = new Map();
  let total = 0;
  function add(name, size, mode) {
    requireThat(typeof name === 'string' && !/[\\:\x00-\x1f]/.test(name), 'Unsafe archive path');
    const parts = name.split('/');
    requireThat(parts.every(part => part && part !== '.' && part !== '..' &&
      !/[. ]$/.test(part) && !/^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)/i.test(part)),
    'Unsafe archive path');
    requireThat(!files.has(name), 'Duplicate archive member');
    requireThat(files.size < limits.entries, 'Archive entry bound exceeded');
    requireThat(Number.isSafeInteger(size) && size >= 0 && size <= limits.file,
      'Archive member size bound exceeded');
    total += size;
    requireThat(total <= limits.archive, 'Archive expanded size bound exceeded');
    requireThat([0o644, 0o755, 0o666, 0o777].includes(mode), 'Invalid archive mode');
    for (let i = 1; i <= parts.length; i++) {
      const prefix = parts.slice(0, i).join('/'), key = pathKey(prefix);
      const previous = aliases.get(key);
      requireThat(!previous || previous === prefix, 'Aliased archive path');
      requireThat(i === parts.length || !files.has(prefix), 'Archive file/directory collision');
      aliases.set(key, prefix);
    }
    requireThat(![...files.keys()].some(file => file.startsWith(name + '/')),
      'Archive file/directory collision');
    const value = {size, mode};
    files.set(name, value);
    return value;
  }
  return {files, add};
}
function parseManifest(bytes, pin, identity) {
  requireThat(bytes.length <= limits.manifest &&
    createHash('sha256').update(bytes).digest('hex') === pin.manifest_sha256,
  'Native manifest differs from pinned digest');
  const value = JSON.parse(new TextDecoder('utf-8', {fatal: true}).decode(bytes));
  requireThat(value && value.version === identity.version && value.target === identity.target &&
    isDeepStrictEqual(value.source, identity.source), 'Native manifest release identity differs');
  requireThat(value.files && typeof value.files === 'object' && !Array.isArray(value.files) &&
    Object.keys(value.files).length > 0 && !Object.hasOwn(value.files, 'manifest.json'),
  'Invalid native file inventory');
  const expected = inventory();
  for (const [name, record] of Object.entries(value.files)) {
    requireThat(record && Object.keys(record).sort().join(',') === 'mode,sha256,size' &&
      digest(record.sha256), 'Invalid native file identity');
    expected.add(name, record.size, record.mode).sha256 = record.sha256;
  }
  expected.add('manifest.json', bytes.length, 0o644).sha256 = pin.manifest_sha256;
  const executable = `bin/${identity.target}/archway${identity.target === 'windows-x64' ? '.exe' : ''}`;
  requireThat(expected.files.get(executable)?.size > 0, 'Native executable missing from inventory');
  return expected.files;
}
function compareInventory(actual, expected) {
  requireThat(actual.size === expected.size, 'Native inventory entry count differs');
  for (const [name, identity] of expected) {
    const observed = actual.get(name);
    requireThat(observed && ['size', 'mode', 'sha256'].every(key => observed[key] === identity[key]),
      `Native inventory differs: ${name}`);
  }
}
module.exports = {limits, requireThat, digest, inventory, parseManifest, compareInventory};
