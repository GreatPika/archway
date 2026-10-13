'use strict';

const {fileURLToPath, pathToFileURL} = require('node:url');
const path = require('node:path');

// Parse the framing independently of JSON.parse, which silently replaces duplicate keys.
function parseJson(text) {
  let offset = 0;
  const whitespace = () => { while (/[\x20\t\r\n]/.test(text[offset] || '\0')) offset++; };
  function string() {
    const start = offset++;
    while (offset < text.length) {
      const character = text[offset++];
      if (character === '"') return JSON.parse(text.slice(start, offset));
      if (character === '\\') offset++;
    }
    throw Error('Unterminated JSON string');
  }
  function value(depth = 0) {
    if (depth > 32) throw Error('Excessive JSON nesting');
    whitespace();
    const opening = text[offset];
    if (opening === '"') return string();
    if (opening === '{' || opening === '[') {
      offset++;
      const object = opening === '{';
      const result = object ? Object.create(null) : [];
      const closing = object ? '}' : ']';
      whitespace();
      if (text[offset] === closing) { offset++; return result; }
      while (true) {
        whitespace();
        if (object) {
          if (text[offset] !== '"') throw Error('Expected JSON object key');
          const key = string();
          if (Object.hasOwn(result, key)) throw Error('Duplicate JSON object key');
          whitespace();
          if (text[offset++] !== ':') throw Error('Expected JSON colon');
          result[key] = value(depth + 1);
        } else result.push(value(depth + 1));
        whitespace();
        if (text[offset] === closing) { offset++; return result; }
        if (text[offset++] !== ',') throw Error('Expected JSON separator');
      }
    }
    const token = /^(?:true|false|null|-?(?:0|[1-9]\d*)(?:\.\d+)?(?:[eE][+-]?\d+)?)/.exec(text.slice(offset));
    if (!token) throw Error('Expected JSON value');
    offset += token[0].length;
    const result = JSON.parse(token[0]);
    if (typeof result === 'number' && !Number.isFinite(result)) throw Error('Nonfinite JSON number');
    return result;
  }
  const result = value();
  whitespace();
  if (offset !== text.length) throw Error('Trailing JSON content');
  return result;
}

function portablePath(value) {
  return typeof value === 'string' && value.length > 0 && value === value.normalize('NFC') &&
    !/[\\\x00-\x1f\x7f:*?"<>|\[\]{}]/.test(value) &&
    value.split('/').every(segment => segment && segment !== '.' && segment !== '..' &&
      !/[. ]$/.test(segment) && !/^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i.test(segment));
}

function scalarCompare(a, b) {
  const left = Array.from(a), right = Array.from(b);
  for (let i = 0; i < Math.min(left.length, right.length); i++) {
    const order = left[i].codePointAt(0) - right[i].codePointAt(0);
    if (order) return order;
  }
  return left.length - right.length;
}

function validateRequest(request) {
  const keys = ['protocol_version', 'request_id', 'project_id', 'root_uri', 'config_path', 'expected_files'];
  if (!request || Array.isArray(request) || typeof request !== 'object' ||
      Object.keys(request).length !== keys.length || keys.some(key => !Object.hasOwn(request, key)) ||
      request.protocol_version !== 2 || typeof request.request_id !== 'string' || !request.request_id ||
      typeof request.project_id !== 'string' || !request.project_id || !portablePath(request.config_path) ||
      !Array.isArray(request.expected_files) ||
      request.expected_files.some((file, i, files) => !portablePath(file) || (i && scalarCompare(files[i - 1], file) >= 0))) {
    throw Error('Invalid helper request');
  }
  if (typeof request.root_uri !== 'string') throw Error('Invalid root URI');
  const uri = new URL(request.root_uri);
  if (uri.protocol !== 'file:' || uri.host || uri.search || uri.hash || /\x00/.test(fileURLToPath(uri))) {
    throw Error('Invalid root URI');
  }
  const root = fileURLToPath(uri);
  if (!path.isAbsolute(root) || pathToFileURL(root).href !== request.root_uri ||
      (root !== path.parse(root).root && root.endsWith(path.sep))) throw Error('Noncanonical root URI');
  return root;
}

module.exports = {parseJson, validateRequest, portablePath, scalarCompare};
