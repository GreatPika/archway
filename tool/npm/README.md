# Archway packages

Archway checks prepared TypeScript and Dart projects against architecture.yaml.
This guide describes the 0.2.0 thin-wrapper design. It is not a claim that these
packages are published or their installation routes certified. Check the
[GitHub releases page](https://github.com/GreatPika/archway/releases) for actual
artifacts; published 0.1.0 downloads remain unchanged. Do not substitute similarly
named registry packages. See the
[staging guide](https://github.com/GreatPika/archway/blob/main/docs/implementation/installation-layout.md).

## Installation routes

The intended npm routes are local development dependency, global installation and
cache/exec using the exact verified package version or tarball. Installation has
no lifecycle scripts. Node launches the small wrapper, which fetches only the
current platform's pinned native archive on first invocation. It needs no C
compiler or Dart SDK for TypeScript-only checks.

The sole pub route, after the exact package is published and verified, is:

```sh
dart pub global activate --no-executables archway VERSION
dart pub global run archway:archway --version
```

Replace VERSION with the selected release. The small Dart snapshot launcher
fetches the same native core; it does not ship the analyzer/core source tree.
Pub uses the longer explicit SDK command for every invocation; native/npm retain
plain archway. No alias is generated, and no setup/repair or launcher rewrite is
needed. Updating means explicitly activating the desired version the same way.
A genuine private hosted Linux fixture passed this SDK route; actual Archway
thin-wrapper platform runs and hosted public installation remain unverified.

Both wrappers use separate user caches independent of your project. First use
requires network access to the pinned native archive; `archway --version` can
prewarm it (for pub: `dart pub global run archway:archway --version`). Offline pub
use requires its prepared activated snapshot under the same pinned SDK and the
verified native cache. SDK switches or missing/stale snapshots can trigger SDK
recompilation; their network/offline behavior requires separate measured checks. There is no setup command, automatic
updater, project dependency installation or SDK download. Unsupported platforms
and corrupt cached payloads fail explicitly; the launcher does not automatically
delete or repair them.

## Usage

After installing a verified package, preview starter files:

```sh
archway --root /path/to/project init --template mixed --dry-run
```

For a local npm installation, prefix the command with `npm exec --offline --`.
For pub, replace archway with `dart pub global run archway:archway` in each command.
Without --root, Archway uses the current directory. Remove --dry-run to create
architecture.yaml and ARCHITECTURE.md, then edit the policy for your project.
Existing files are never overwritten or merged. Init also refuses ASCII-case
variants of either output name on every OS. An old ARCHITECTURE_AGENT.md is left
untouched; no migration or deletion happens automatically.

Use validate, owner, node, allows, check or export --format mermaid as needed.
Check reads already-prepared projects and never installs dependencies or runs
project builds, scripts or plugins. Operational results are JSON; export emits
Mermaid with separate JSON diagnostics. Check exits 0 for complete clean analysis,
1 for complete violations, and 2 for invalid policy or incomplete analysis.
Use command-specific --help for options.

## Runtimes, layout and integrity

Native policy/query/init/export need neither Node nor an external Dart SDK.
npm needs Node to launch. Pub needs pinned Dart 3.13.3 for activation and every
explicit global-run invocation. TypeScript check requires Node
24.21.0 and bundled TypeScript 5.9.3. Dart check requires external Dart 3.13.3 and
prepared mappings. Neither runtime is downloaded by Archway.

Native payloads retain bin/<target>/archway (archway.exe on Windows), native/
bridges, assets/, schemas/ and manifest.json. Keep portable installations whole.
Acquisition verifies archive bytes and the complete manifest inventory before
atomic cache publication. Warm launch hashes the pinned manifest and executable;
other assets retain the core's path/runtime checks, not full warm digest checks.
These checks detect corruption, not malicious same-user replacement or publisher
authenticity. Prelaunch errors use stderr/exit 126; core arguments, streams and
exits pass through unchanged. Signal behavior is OS-specific.

If the installation is inside the inspected project, configure scope and exclude
explicitly. Archway is MIT licensed; licenses/notices remain with their owning
wrapper and native dependency assets.

### Packed launcher permissions

The canonical source inventory records `bin/archway.cjs` as `0755`. npm can
pack that declared bin as `0644` on Windows. Packed admission accepts exactly
these two complete inventories, differing only in that launcher's mode; every
member's bytes, size, name and other permissions remain pinned. npm installation
makes declared bins executable and creates the platform command links/shims.
This npm transport rule does not change native payload archive permissions.
