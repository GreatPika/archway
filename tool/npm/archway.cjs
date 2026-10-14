#!/usr/bin/env node
'use strict';
// Transport only. The native core owns arguments, results and analysis policy.
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const {spawn} = require('node:child_process');
function fail(error) {
  process.stderr.write(`archway launcher: ${error.message}\n`);
  process.exitCode = 126;
}
async function main() {
  const target = {'linux/x64': 'linux-x64', 'darwin/arm64': 'macos-arm64',
    'win32/x64': 'windows-x64'}[`${process.platform}/${process.arch}`];
  if (!target) throw new Error(`unsupported target ${process.platform}/${process.arch}`);
  const root = path.dirname(path.dirname(__filename));
  function metadata(name) {
    const file = path.join(root, name), stat = fs.lstatSync(file);
    if (!stat.isFile() || fs.realpathSync(file) !== file || stat.size > 2 * 1024 * 1024)
      throw new Error('package metadata is missing, oversized or aliased');
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  }
  const descriptor = metadata('acquisition.json'), packageInfo = metadata('package.json');
  if (packageInfo.name !== 'archway-architecture-cli' || packageInfo.version !== descriptor.version)
    throw new Error('package and native release identities differ');
  const home = os.homedir();
  const userCache = process.platform === 'win32'
    ? process.env.LOCALAPPDATA || path.join(home, 'AppData', 'Local')
    : process.platform === 'darwin' ? path.join(home, 'Library', 'Caches')
      : process.env.XDG_CACHE_HOME || path.join(home, '.cache');
  if (!path.isAbsolute(userCache)) throw new Error('user cache location must be absolute');
  const executable = await require('./cache.cjs').acquireNative(
    descriptor, target, path.join(userCache, 'archway', 'npm'));
  const child = spawn(executable, process.argv.slice(2), {stdio: 'inherit', shell: false});
  const forwarders = new Map();
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    const forward = () => child.kill(signal);
    forwarders.set(signal, forward);
    process.on(signal, forward);
  }
  function removeForwarders() {
    for (const [signal, forward] of forwarders) process.removeListener(signal, forward);
  }
  child.once('error', error => { removeForwarders(); fail(error); });
  child.once('exit', (code, signal) => {
    removeForwarders();
    if (signal) process.kill(process.pid, signal);
    else process.exitCode = code;
  });
}
main().catch(fail);
