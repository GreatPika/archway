'use strict';
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const zlib = require('node:zlib');
const {createHash} = require('node:crypto');
const {Transform} = require('node:stream');
const {pipeline} = require('node:stream/promises');
const {Parser} = require('tar');
const yauzl = require('yauzl');
const {limits, requireThat, digest, inventory, parseManifest, compareInventory} = require('./inventory.cjs');

async function canonical(name, directory = false) {
  const stat = await fsp.lstat(name);
  requireThat(path.isAbsolute(name) && path.normalize(name) === name &&
    (directory ? stat.isDirectory() : stat.isFile()) && await fsp.realpath(name) === name,
  'Expected ordinary canonical archive path');
  return stat;
}
async function absent(name) {
  try { await fsp.lstat(name); } catch (error) {
    if (error.code === 'ENOENT') return;
    throw error;
  }
  throw new Error('Extraction destination already exists');
}
function byteLimit(max, message, hash) {
  let total = 0;
  return new Transform({transform(chunk, encoding, callback) {
    total += chunk.length;
    if (total > max) return callback(new Error(message));
    hash?.update(chunk);
    callback(null, chunk);
  }});
}
async function snapshot(source, output, pin) {
  requireThat(Number.isSafeInteger(pin.size) && pin.size > 0 && pin.size <= limits.archive &&
    digest(pin.sha256) && digest(pin.manifest_sha256), 'Invalid native archive pin');
  requireThat((await canonical(source)).size === pin.size, 'Native archive size differs from pin');
  const hash = createHash('sha256');
  await pipeline(fs.createReadStream(source), byteLimit(pin.size, 'Native archive exceeds pin', hash),
    fs.createWriteStream(output, {flags: 'wx', mode: 0o600}));
  requireThat((await fsp.stat(output)).size === pin.size && hash.digest('hex') === pin.sha256,
    'Native archive digest differs from pin');
}
function outputFile(root, name, mode) {
  const output = path.join(root, ...name.split('/'));
  fs.mkdirSync(path.dirname(output), {recursive: true, mode: 0o700});
  return fs.openSync(output, 'wx', mode);
}
async function tarPass(file, output) {
  const observed = inventory(), outputs = new Set();
  const parser = new Parser({strict: true, maxMetaEntrySize: limits.manifest});
  let metadata = 0;
  parser.on('meta', () => {
    if (++metadata > limits.entries) parser.abort(new Error('Archive metadata count exceeded'));
  });
  parser.on('ignoredEntry', () => parser.abort(new Error('Unsupported archive entry')));
  parser.on('entry', entry => {
    try {
      requireThat(['File', 'OldFile'].includes(entry.type) && !entry.linkpath,
        'Expected ordinary archive file');
      requireThat(entry.path === entry.header.path, 'Normalized archive path refused');
      const item = observed.add(entry.header.path, entry.size, entry.header.mode);
      const keep = entry.path === 'manifest.json';
      requireThat(!keep || entry.size <= limits.manifest, 'Native manifest exceeds bound');
      const chunks = [], hash = createHash('sha256');
      const fd = output ? outputFile(output, entry.path, entry.header.mode) : null;
      if (fd !== null) outputs.add(fd);
      let count = 0;
      entry.on('data', chunk => {
        count += chunk.length;
        if (count > item.size) return parser.abort(new Error('Archive member exceeds size'));
        hash.update(chunk);
        if (keep) chunks.push(chunk);
        if (fd !== null) {
          try { fs.writeFileSync(fd, chunk); } catch (error) { parser.abort(error); }
        }
      });
      entry.on('end', () => {
        if (count !== item.size) return parser.abort(new Error('Archive member size differs'));
        item.sha256 = hash.digest('hex');
        if (keep) item.bytes = Buffer.concat(chunks);
        if (fd !== null) {
          try {
            if (process.platform !== 'win32') fs.fchmodSync(fd, entry.header.mode);
            fs.closeSync(fd); outputs.delete(fd);
          } catch (error) { parser.abort(error); }
        }
      });
      entry.resume();
    } catch (error) { parser.abort(error); }
  });
  try {
    await pipeline(fs.createReadStream(file), zlib.createGunzip(),
      byteLimit(limits.archive, 'Archive expanded size bound exceeded'), parser);
  } finally { for (const fd of outputs) fs.closeSync(fd); }
  return observed.files;
}
async function zipPass(file, output) {
  const zip = await yauzl.openPromise(file, {lazyEntries: true, strictFileNames: true,
    autoClose: false, validateEntrySizes: true});
  const observed = inventory();
  try {
    for await (const entry of zip.eachEntry()) {
      const mode = entry.externalFileAttributes >>> 16;
      requireThat((mode & 0xf000) === 0x8000 && (entry.externalFileAttributes & 0x10) === 0,
        'Expected ordinary archive file');
      requireThat(!entry.isEncrypted() && [0, 8].includes(entry.compressionMethod),
        'Unsupported ZIP encoding');
      const item = observed.add(entry.fileName, entry.uncompressedSize, mode & 0xfff);
      const local = await zip.readLocalFileHeaderPromise(entry);
      requireThat(local.fileName.equals(Buffer.from(entry.fileName)) &&
        local.generalPurposeBitFlag === entry.generalPurposeBitFlag &&
        local.compressionMethod === entry.compressionMethod &&
        ((entry.generalPurposeBitFlag & 8) !== 0 ||
          (local.compressedSize === entry.compressedSize &&
           local.uncompressedSize === entry.uncompressedSize && local.crc32 === entry.crc32)),
      'ZIP local header differs');
      const keep = entry.fileName === 'manifest.json';
      requireThat(!keep || item.size <= limits.manifest, 'Native manifest exceeds bound');
      const hash = createHash('sha256'), chunks = [];
      let size = 0;
      // Omit decodeFileData: yauzl 3.4.0's explicit option differs from its default.
      const stream = await zip.openReadStreamPromise(entry);
      let fd = null;
      try {
        if (output) fd = outputFile(output, entry.fileName, mode & 0xfff);
        for await (const chunk of stream) {
          size += chunk.length;
          requireThat(size <= item.size, 'Archive member exceeds size');
          hash.update(chunk);
          if (keep) chunks.push(chunk);
          if (fd !== null) fs.writeFileSync(fd, chunk);
        }
        requireThat(size === item.size, 'Archive member size differs');
        if (fd !== null && process.platform !== 'win32') fs.fchmodSync(fd, mode & 0xfff);
      } finally { stream.destroy(); if (fd !== null) fs.closeSync(fd); }
      item.sha256 = hash.digest('hex');
      if (keep) item.bytes = Buffer.concat(chunks);
    }
    return observed.files;
  } finally { zip.close(); }
}

// Private acquisition owner: writes only a new directory, after full admission.
// Cache publication is separate; callers never execute this incomplete stage.
async function extractNativeArchive(source, pin, identity, destination) {
  requireThat(path.isAbsolute(destination) && path.normalize(destination) === destination,
    'Expected canonical extraction destination');
  await canonical(path.dirname(destination), true);
  await absent(destination);
  const workspace = await fsp.mkdtemp(path.join(path.dirname(destination), '.archway-archive-'));
  let owned = false, complete = false;
  try {
    const input = path.join(workspace, 'input');
    await snapshot(source, input, pin);
    const read = identity.target === 'windows-x64' ? zipPass : tarPass;
    const files = await read(input);
    requireThat(files.has('manifest.json'), 'Native root manifest missing');
    const expected = parseManifest(files.get('manifest.json').bytes, pin, identity);
    compareInventory(files, expected);
    await fsp.mkdir(destination, {mode: 0o700});
    owned = true;
    compareInventory(await read(input, destination), expected);
    complete = true;
  } finally {
    if (owned && !complete) await fsp.rm(destination, {recursive: true});
    await fsp.rm(workspace, {recursive: true});
  }
}
module.exports = {extractNativeArchive};
