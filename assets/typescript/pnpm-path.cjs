'use strict';
// Adapted from pnpm v9.15.9 packages/dependency-path and crypto.base32-hash.
// MIT: see licenses/pnpm-MIT.txt. This only verifies a lock-named instance;
// directory spelling is never decoded to infer a package's origin.
const {createHash} = require('node:crypto');
function base32Hash(text) {
  let bits = 0, value = 0, output = '';
  for (const byte of createHash('md5').update(text).digest()) {
    value = (value << 8) | byte;
    bits += 8;
    while (bits >= 5) { bits -= 5; output += 'abcdefghijklmnopqrstuvwxyz234567'[(value >>> bits) & 31]; }
  }
  if (bits) output += 'abcdefghijklmnopqrstuvwxyz234567'[(value << (5 - bits)) & 31];
  return output;
}
function depPathToFilename(depPath, maxLengthWithoutHash) {
  if (!Number.isInteger(maxLengthWithoutHash) || maxLengthWithoutHash < 28 || maxLengthWithoutHash > 1024) throw Error('Invalid virtual store length');
  let filename = (depPath.startsWith('file:') ? depPath.replace(':', '+') : depPath.replace(/^\//, ''))
    .replace(/[\\/:*?"<>|]/g, '+');
  if (filename.includes('(')) filename = filename.replace(/\)$/, '').replace(/(\)\()|\(|\)/g, '_');
  if (filename.length > maxLengthWithoutHash || filename !== filename.toLowerCase() && !filename.startsWith('file+')) {
    return `${filename.substring(0, maxLengthWithoutHash - 27)}_${base32Hash(filename)}`;
  }
  return filename;
}
module.exports = {depPathToFilename};
