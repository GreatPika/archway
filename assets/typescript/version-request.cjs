'use strict';
// TypeScript 5.9.3's own pinned semver implementation (typescript.js 4808+).
// Its range test includes prereleases, so this profile only accepts prerelease
// versions under exact pins. No registry lookup or handwritten semver arithmetic.
function versionRequest(ts, source, manifest) {
  if (typeof source !== 'string' || typeof manifest.version !== 'string') return false;
  const version = ts.Version.tryParse(manifest.version);
  if (!version) return false;
  if (/^(?:file:|link:|https?:|git[+:]|ssh:|github:|gitlab:|bitbucket:)/.test(source)) return true;
  if (source.startsWith('npm:')) {
    const alias = /^(@[^/]+\/[^@]+|[^@]+)(?:@(.+))?$/.exec(source.slice(4));
    if (!alias || alias[1] !== manifest.name) return false;
    source = alias[2] || '*';
  }
  if (source.startsWith('workspace:')) {
    source = source.slice(10);
    if (['*', '^', '~'].includes(source)) return true;
  }
  const range = ts.VersionRange.tryParse(source);
  if (range) {
    if (version.prerelease.length && source !== manifest.version && source !== '=' + manifest.version) return false;
    return range.test(version);
  }
  // A dist-tag is selected by the matching prepared lock, not by today's registry.
  return !version.prerelease.length && /^[A-Za-z][A-Za-z0-9._-]*$/.test(source);
}
module.exports = {versionRequest};
