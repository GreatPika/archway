'use strict';

const fs = require('node:fs');
const path = require('node:path');
const {fileURLToPath, pathToFileURL} = require('node:url');
const {createHash} = require('node:crypto');
const {scalarCompare} = require('./framing.cjs');
const names = ['readFileSync', 'readdirSync', 'statSync', 'lstatSync', 'realpathSync', 'readlinkSync', 'existsSync'];
const original = Object.fromEntries(names.map(name => [name, fs[name]]));
const raw = Object.fromEntries(names.map(name => [name, original[name].bind(fs)]));
const nativeRealpath = original.realpathSync.native;
const hash = bytes => createHash('sha256').update(bytes).digest('hex');
const absent = error => error?.code === 'ENOENT' || error?.code === 'ENOTDIR';

// This isolated, synchronous process audits the pinned compiler's Node System routes.
// In TS 5.9.3 reads/stat/readdir use the mutable fs object, but realpath is captured.
function trace(response, run) {
  const signatures = new Map();
  const reads = new Map();
  const errors = new Set();
  let nested = false;
  function gap(error) {
    const message = String(error.message || error);
    if (!errors.has(message)) {
      errors.add(message);
      response.tool_errors.push({code: 'TYPESCRIPT_INPUT_TRACE_FAILED', message, path: null, source_range: null});
    }
  }
  function record(input) {
    const signature = JSON.stringify(input);
    if (signatures.has(signature)) return signatures.get(signature);
    const result = {id: `input:${response.inputs.length}`, ...input};
    signatures.set(signature, result);
    response.inputs.push(result);
    return result;
  }
  function route(input) {
    const symlink_hops = [], active = new Set();
    let expansions = 0;
    function walk(input) {
      let prefix = path.parse(input).root;
      for (const segment of input.slice(prefix.length).split(path.sep).filter(Boolean)) {
        if (segment === '.') continue;
        if (segment === '..') { prefix = path.dirname(prefix); continue; }
        prefix = path.join(prefix, segment);
        let entry;
        try { entry = raw.lstatSync(prefix); }
        catch (error) { if (absent(error)) continue; throw error; }
        if (!entry.isSymbolicLink()) continue;
        if (++expansions > 40 || active.has(prefix)) throw Error(`Cannot verify cyclic alias chain: ${prefix}`);
        const link = prefix;
        active.add(link);
        const target = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true}).decode(raw.readlinkSync(link, {encoding: 'buffer'}));
        symlink_hops.push({observed_uri: pathToFileURL(link).href, target});
        const expanded = path.isAbsolute(target) ? target : path.dirname(link) + path.sep + target;
        prefix = walk(expanded);
        // Validate the uncollapsed kernel route, including missing/file + '..'.
        raw.statSync(expanded);
        active.delete(link);
      }
      return prefix;
    }
    return {canonical: walk(input), symlink_hops};
  }
  function canonicalIdentity(file, physical) {
    // Native realpath and Dart agree on APFS entry spelling; Node's JavaScript
    // realpath can preserve a case probe's spelling. Never erase an extra hop.
    const canonical = nativeRealpath.call(fs, file);
    if (physical.canonical !== canonical) {
      function unchanged() {
        const endpoint = route(physical.canonical);
        if (endpoint.symlink_hops.length || endpoint.canonical !== physical.canonical ||
            JSON.stringify(route(file)) !== JSON.stringify(physical)) {
          throw Error(`Physical route changed during canonicalization: ${file}`);
        }
      }
      unchanged();
      if (nativeRealpath.call(fs, physical.canonical) !== canonical) {
        throw Error(`Physical pathname identity changed: ${file}`);
      }
      unchanged();
    }
    return pathToFileURL(canonical).href;
  }
  function observe(input, bytes, entries, missing = false, aliases = true) {
    const file = path.resolve(input instanceof URL ? fileURLToPath(input) : String(input));
    const observed_uri = pathToFileURL(file).href;
    const physical = route(file);
    const symlink_hops = physical.symlink_hops;
    if (missing) return record({kind: 'absent', observed_uri, canonical_uri: null, symlink_hops});
    let stat;
    try { stat = raw.statSync(file); }
    catch (error) {
      if (absent(error)) return record({kind: 'absent', observed_uri, canonical_uri: null, symlink_hops});
      throw error;
    }
    const canonical_uri = canonicalIdentity(file, physical);
    let result;
    if (stat.isFile()) {
      const exact = bytes === undefined ? raw.readFileSync(file) : bytes;
      if (!Buffer.isBuffer(exact)) throw Error(`Untraceable non-byte read: ${file}`);
      result = record({kind: 'file', observed_uri, canonical_uri, symlink_hops, sha256: hash(exact)});
      if (bytes !== undefined) reads.set(file, {input: result, bytes: Buffer.from(exact)});
    } else if (stat.isDirectory()) {
      function inventoryOf(entries) {
        return entries.map(entry => {
          const name = Buffer.isBuffer(entry.name) ? new TextDecoder('utf-8', {fatal: true, ignoreBOM: true}).decode(entry.name) : entry.name;
          if (typeof name !== 'string') throw Error(`Untraceable directory entry: ${file}`);
          return [name, entry.isSymbolicLink() ? 'symlink' : entry.isFile() ? 'file' : entry.isDirectory() ? 'directory' : 'other'];
        }).sort((a, b) => scalarCompare(a[0], b[0]) || scalarCompare(a[1], b[1]));
      }
      const inventory = inventoryOf(raw.readdirSync(file, {withFileTypes: true, encoding: 'buffer'}));
      if (entries && JSON.stringify(inventoryOf(entries)) !== JSON.stringify(inventory)) {
        throw Error(`Directory entries changed during observation: ${file}`);
      }
      result = record({kind: 'directory', observed_uri, canonical_uri, symlink_hops, sha256: hash(Buffer.from(JSON.stringify(inventory)))});
    } else throw Error(`Unsupported filesystem input: ${file}`);
    if (aliases && symlink_hops.length) {
      for (const hop of symlink_hops) observe(fileURLToPath(hop.observed_uri), undefined, undefined, false, false);
    }
    return result;
  }
  function wrapped(name, operation) { return function(file, ...args) {
    if (nested) return operation(file, ...args);
    nested = true;
    try {
      let result;
      const encoding = name === 'readFileSync' && (typeof args[0] === 'string' ? args[0] : args[0]?.encoding);
      // Node's trusted module loader asks for UTF-8. Read bytes once, hash those
      // exact bytes, then provide the requested decoding to the original caller.
      const operationArgs = encoding ? [{...(typeof args[0] === 'object' ? args[0] : {}), encoding: null}] : args;
      try { result = operation(file, ...operationArgs); }
      catch (error) {
        if (absent(error)) {
          try { observe(file, undefined, undefined, true); }
          catch (traceError) { gap(traceError); }
        } else gap(error);
        throw error;
      }
      try {
        const missing = (name === 'statSync' || name === 'lstatSync') && !result || name === 'existsSync' && !result;
        // existsSync hides permissions as false; only a confirmed absent stat
        // permits a negative observation. Other errors become explicit gaps.
        if (name === 'existsSync' && !result && raw.statSync(file, {throwIfNoEntry: false})) {
          throw Error(`Filesystem existence changed during observation: ${file}`);
        }
        if (name === 'readFileSync' && !Buffer.isBuffer(result)) throw Error(`Untraceable decoded read: ${file}`);
        const observation = observe(file, name === 'readFileSync' ? result : undefined,
          name === 'readdirSync' && args[0]?.withFileTypes ? result : undefined, missing);
        let expected;
        if ((name === 'statSync' || name === 'lstatSync') && result) {
          if (name === 'lstatSync' && result.isSymbolicLink()) {
            if (!raw.lstatSync(file).isSymbolicLink()) throw Error(`Filesystem symlink changed during observation: ${file}`);
          } else expected = result.isFile() ? 'file' : result.isDirectory() ? 'directory' : 'other';
        } else if (name === 'readFileSync') expected = 'file';
        else if (name === 'readdirSync') expected = 'directory';
        if (expected && observation.kind !== expected || name === 'existsSync' && result && observation.kind === 'absent') {
          throw Error(`Filesystem operation and observation disagree: ${file}`);
        }
        if (name === 'realpathSync') {
          if (typeof result !== 'string') throw Error(`Untraceable realpath result: ${file}`);
          const returned = path.resolve(result), resultRoute = route(returned);
          if (resultRoute.symlink_hops.length ||
              canonicalIdentity(returned, resultRoute) !== observation.canonical_uri) {
            throw Error(`Filesystem realpath changed during observation: ${file}`);
          }
        }
      } catch (error) { gap(error); }
      return encoding ? result.toString(encoding) : result;
    } finally { nested = false; }
  }; }
  for (const name of names) fs[name] = wrapped(name, raw[name]);
  // Install before loading TypeScript: both its native realpath capture and its
  // module-initialization case-sensitivity probe must pass through this observer.
  if (nativeRealpath) fs.realpathSync.native = wrapped('realpathSync', nativeRealpath.bind(fs));
  try { return run({observe, reads, gap}); }
  finally {
    for (const name of names) fs[name] = original[name];
  }
}

module.exports = {trace};
