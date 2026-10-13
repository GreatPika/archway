#!/usr/bin/env node
'use strict';
// Only transport belongs here. The native core owns CLI parsing and results.
const fs = require('node:fs');
const path = require('node:path');
const {createHash} = require('node:crypto');
const {spawn} = require('node:child_process');
const targets = {
  'linux/x64': ['linux-x64', 'archway'],
  'darwin/arm64': ['macos-arm64', 'archway'],
  'win32/x64': ['windows-x64', 'archway.exe'],
};
function fail(message) {
  process.stderr.write(`archway launcher: ${message}\n`);
  process.exitCode = 126;
}
const target = targets[`${process.platform}/${process.arch}`];
if (!target) {
  fail(`unsupported target ${process.platform}/${process.arch}`);
} else {
  const root = path.dirname(path.dirname(__filename));
  const executable = path.join(root, 'bin', ...target);
  try {
    if (!fs.lstatSync(executable).isFile() || fs.realpathSync(executable) !== executable) {
      throw new Error('payload is aliased or is not an ordinary file');
    }
    // Detect corruption against the generated manifest, not installation authenticity.
    // This also prevents Node's ENOEXEC text-file shell fallback for changed payloads.
    const manifest = path.join(root, 'manifest.json');
    if (!fs.lstatSync(manifest).isFile() || fs.realpathSync(manifest) !== manifest) {
      throw new Error('payload manifest is missing or aliased');
    }
    const expected = JSON.parse(fs.readFileSync(manifest, 'utf8')).sha256[
      `bin/${target[0]}/${target[1]}`];
    const actual = createHash('sha256').update(fs.readFileSync(executable)).digest('hex');
    if (!/^[a-f0-9]{64}$/.test(expected) || actual !== expected) {
      throw new Error('payload integrity check failed');
    }
    const child = spawn(executable, process.argv.slice(2), {stdio: 'inherit', shell: false});
    child.once('error', error => fail(`cannot start ${target[0]} payload: ${error.message}`));
    child.once('exit', (code, signal) => {
      if (signal) {
        process.removeAllListeners(signal);
        process.kill(process.pid, signal);
      } else {
        process.exitCode = code;
      }
    });
    for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
      process.on(signal, () => child.kill(signal));
    }
  } catch (error) {
    fail(`cannot start ${target[0]} payload: ${error.message}`);
  }
}
