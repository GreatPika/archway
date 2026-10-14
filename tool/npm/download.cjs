'use strict';
const fs = require('node:fs/promises');
const https = require('node:https');
const {Transform} = require('node:stream');
const {pipeline} = require('node:stream/promises');
const {limits, requireThat} = require('./inventory.cjs');

// A shorter private budget is useful for transport fixtures; no CLI/env override.
async function downloadNativeArchive(url, destination, expectedBytes, timeout = 120000) {
  requireThat(Number.isSafeInteger(expectedBytes) && expectedBytes > 0 && expectedBytes <= limits.archive &&
    Number.isSafeInteger(timeout) && timeout > 0 && timeout <= 120000, 'Invalid native download bound');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(new Error('Native download timed out')), timeout);
  let owned = false, complete = false;
  try {
    for (let redirects = 0; ; redirects++) {
      requireThat(url.protocol === 'https:' && url.hostname && !url.username && !url.password && !url.hash,
        'Native download requires HTTPS without credentials or fragments');
      const response = await new Promise((resolve, reject) => {
        const request = https.get(url, {signal: controller.signal, headers: {'accept-encoding': 'identity'}}, resolve);
        request.once('error', reject);
      });
      try {
        if ([301, 302, 303, 307, 308].includes(response.statusCode)) {
          requireThat(redirects < 5 && typeof response.headers.location === 'string',
            'Native download redirect limit or location invalid');
          url = new URL(response.headers.location, url);
          continue;
        }
        requireThat(response.statusCode === 200, `Native download HTTP ${response.statusCode}`);
        const length = response.headers['content-length'];
        requireThat(length === undefined || /^\d+$/.test(length) && Number(length) === expectedBytes,
          'Native download declared size differs');
        requireThat(!response.headers['content-encoding'] || response.headers['content-encoding'] === 'identity',
          'Unexpected native download content encoding');
        const handle = await fs.open(destination, 'wx', 0o600);
        owned = true;
        let count = 0;
        const bounded = new Transform({transform(chunk, encoding, callback) {
          count += chunk.length;
          callback(count > expectedBytes ? new Error('Native download exceeds pinned size') : null, chunk);
        }});
        await pipeline(response, bounded, handle.createWriteStream(), {signal: controller.signal});
        requireThat(count === expectedBytes, 'Native download size differs');
        complete = true;
        return;
      } finally { response.destroy(); }
    }
  } catch (error) {
    if (controller.signal.aborted) throw controller.signal.reason;
    throw error;
  } finally {
    clearTimeout(timer);
    if (owned && !complete) await fs.unlink(destination);
  }
}
module.exports = {downloadNativeArchive};
