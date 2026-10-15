# Package delivery contract

The 0.2.0 preview keeps native archives and replaces the bundled npm/source-pub
routes with thin launchers for the same native core. These are requirements,
not certification or publication claims. Published 0.1.0 artifacts are immutable.
Policy and helper protocol versions are unchanged. The separate init filename
amendment is recorded in [the public contract](../json/decision.md#safe-init-including-partial-outcomes).

## One core, three delivery forms

- The same Dart AOT CLI owns arguments, policy, JSON, streams and exits. Native
  archives retain the three target cells in [decisions.md](decisions.md), native
  bridges, helper, pinned TypeScript/lib files, schemas, manifests, licenses and guide.
- npm contains a thin JavaScript launcher. pub contains a separate small Dart
  launcher staged from tool/pub, not the core source or analyzer dependencies.
  Keep bin/archway.dart as the core entrypoint. Install the pub wrapper with
  `dart pub global activate --no-executables archway VERSION`, then invoke it with
  `dart pub global run archway:archway <args>`. No generated command alias,
  launcher rewrite or setup/repair step is used. Native/npm retain plain archway;
  pub deliberately uses the longer explicit SDK command. No alternative pub
  installation or invocation route is advertised.
- Both wrappers consume one generated descriptor pinned to the package release:
  version, source identity, target, immutable HTTPS native-archive URL, archive
  byte size and SHA-256, and root-manifest SHA-256. Unsupported targets fail
  explicitly. There is no runtime URL override or public cache-seeding interface.
- First invocation fetches only the selected target's native payload. Running
  `archway --version` (pub: `dart pub global run archway:archway --version`) may
  prewarm it. Offline pub use requires a prepared activated snapshot under the
  same SDK and a verified native cache. SDK switches or missing/stale snapshots
  can trigger SDK recompilation; their behavior requires measured acceptance,
  not an unconditional no-network promise. SDK preparation can print progress
  before native stdout on the first switched invocation; prewarm with the explicit
  pub `--version` invocation before capturing machine-readable output.
  No lifecycle/install
  scripts, native-payload/analysis-compiler builds, project dependency installation,
  SDK downloads,
  automatic updater, cache garbage collection or separate setup command exists.
- npm needs Node to launch; pub needs the pinned Dart SDK for activation and
  every invocation of its snapshot launcher. Native policy/query/init/
  export need neither external runtime. TypeScript check needs verified external
  Node; Dart check needs the verified external SDK. Analysis pins remain unchanged;
  runtimes are not bundled or downloaded. Payload acquisition precedes the core
  invocation and does not permit network access during inspection.

## Acquisition, cache and process boundary

Each wrapper owns a separate OS-user cache, independent of cwd and keyed by
version, target and archive digest. The two wrappers do not share cache ownership.
Use bounded HTTPS redirects compatible with GitHub's CDN, reject HTTPS downgrade,
apply finite timeouts and byte limits, and require the descriptor's exact archive
size and digest. No unpinned fallback download is allowed.

Use pinned maintained archive libraries supporting the producer's PAX tar.gz and
ZIP formats. Validate ordinary entries, path confinement, link refusal, duplicate
and alias refusal, entry counts and expanded-size bounds before extraction writes.
Verify the pinned root manifest and its full file inventory before publishing a
unique temporary extraction atomically. Validate a concurrent winner before use.
Interrupted or failed acquisition must not become a usable installation. Corrupt
existing cache entries fail closed without automatic deletion or repair.

Warm launch hashes the pinned root manifest and selected executable only. The core
retains its canonical-path and runtime checks for other assets; this is not full
warm asset-digest verification. Hashes detect corruption and bind build provenance,
not signatures, authenticity or protection from same-user tampering.

Spawn the native executable directly without a shell, inheriting stdin/stdout/
stderr and forwarding argv and core exit codes. Prelaunch failures use stderr and
exit 126, outside core JSON; no stdout progress. Measure termination and signal
behavior on each OS rather than promising identical semantics.

## Private installation layout

The unchanged native layout is bin/<target>/archway (archway.exe on Windows),
native/<target>/ bridges and assets/ shared files. The private layout owner uses
Archway's own package URI for core source development or its canonical staged
native executable. Moving a whole native installation is supported; missing or
aliased required assets fail the affected operation. No cwd, project compiler,
node_modules, upward package-config search or source/native fallback is allowed.
The generated assets/typescript/vendor/typescript/ tree contains the unmodified
pinned package, lib files and license, prepared from the pinned build-time lock.

An explicitly invoked installation is trusted even inside the inspected root.
Preserve canonical/no-alias checks and external-runtime environment filtering.
This does not authorize project wrappers, plugins or loaders, and is not a sandbox
against modified installations. Installation location does not silently change
scope minus exclude; explicitly selected installed sources remain in the corpus.

## Artifact production and publication

Build native archives first from canonical source/installation version metadata,
then generate the descriptor from their exact bytes, then stage wrapper packages,
then run local installed-route tests. Native archive creation must not depend on
an npm manifest or wrapper artifact. Native assembly has one owner; final release
aggregation consumes the independently built native and wrapper artifacts.

Keep source/default developer stages private. An explicit registry-ready stage
may set publication metadata before hashing complete candidates; staging never
publishes, authenticates, reserves names or certifies a route. Never edit certified
bytes to make a private candidate publishable. Archive, descriptor, package and
receipt evidence must agree on exact version, source, target and artifact bytes.

Native artifact upload requires separate authorization. After upload, a real
cold fetch from the pinned hosted URLs must pass before separately authorized
registry publication. Local transport injection and installed-package tests do
not establish hosted URL availability or registry installation acceptance.

## Required installation evidence

Keep every original native platform/runtime gate: Linux x64 Ubuntu 24.04/glibc,
macOS arm64 macOS 15/APFS and Windows x64 Windows 11 24H2/NTFS. Build and extract
real artifacts, relocate them, and exercise runtime absence/failure, real compiler
fixtures, native writes, aliases, spaces/Unicode and no project-code execution.
Server CI evidence does not by itself certify the desktop target.

Test actual packed npm local, global and cache/exec routes with scripts disabled,
and actual pub activation with --no-executables followed by explicit global run
of the staged launcher. Prove no generated alias, snapshot dispatch, exact argv/
stdout/stderr/exit propagation and no run-time HTTP with both the same-SDK
prepared snapshot and verified native cache. Cold native-payload acquisition
remains a separate download case.
Include missing/stale snapshot and SDK-switch controls, cold payload acquisition,
offline warm runs from another cwd, one-target fetch, independent user caches,
concurrent publication, interruption, corrupt cache, invalid/oversize/traversing/
linked/aliased archives, bounded redirects/timeouts and unsupported targets.
Assert argv, streams, exits, OS-specific termination and exact artifact inventories.
Installed command and artifact inventories remain public test seams; injected
transport/cache/extraction controls are private fixture seams only.

A genuine private hosted fixture on pinned Dart 3.13.3 Linux validates activation
without generated executables, cold/warm explicit global run, exact argv/streams/
exit 37, and no HTTP during execution. With the fixture server stopped, execution
still passes; poisoning the still-present cached source proves snapshot dispatch.
This establishes the bounded SDK route, not actual Archway thin-wrapper acceptance
on Linux/macOS/Windows or hosted public Archway installation. Those remain gates.
Hosted-URL native cold fetch and registry installation are separately measured.
Report unrun or failing gates explicitly; no local test or this document authorizes
publication or claims release readiness.
