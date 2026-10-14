# Native and package delivery gates

This is a map of the executable checks, commands and evidence boundaries. A green
probe establishes its selected cases only. The [delivery contract](../../contracts/compatibility/delivery.md)
and [acceptance targets](../../docs/spec/acceptance.md) define certification.
Run commands from the repository root; replace uppercase arguments with prepared
paths and independently verified identities.

## Workflow map

- [Package delivery](../../.github/workflows/package-delivery-probe.yml) is the
  push entry point (`main`, `integration/archway-v1`, `release/**`, filtered paths)
  and supports manual dispatch. It calls both native workflows with export enabled,
  adds Ubuntu 24.04 x64 / glibc 2.39, audits same-source transports, packs npm once,
  and runs installed consumers on all three hosts.
- [macOS source and AOT](../../.github/workflows/macos-native-probe.yml) supports
  reusable calls and manual dispatch on macOS 15 arm64. It records APFS temp-root
  and case behavior, canonical paths and Apple SDK/clang readiness. Successful init
  is required.
- [Windows native](../../.github/workflows/windows-native-probe.yml) supports
  reusable calls and manual dispatch on Windows Server 2025 x64, with inspected
  NTFS roots and installed Visual Studio x64 C tools/Windows SDK. Server evidence
  is **not Windows 11 24H2 certification**.

The workflow files and [Windows setup](windows-native-probe.ps1) own runtime
checksums and action pins: Dart 3.13.3, Node 24.21.0 and npm 11.19.0. Setup preserves
both lockfiles and prepares only owned TypeScript 5.9.3 / yaml 2.8.1 assets:

```sh
dart --suppress-analytics pub get --enforce-lockfile
bash tool/prepare_typescript.sh
```

Windows assembly requires PowerShell, explicit pinned Dart, and verified Git for
Windows Bash with pinned Node/npm first on PATH. Source policy/init controls
need no Node.

Jobs use bounded timeouts, `contents: read`, pinned actions and nonpersistent
checkout credentials. Native export/probe runs have separate cancellation groups.
One-day artifacts retain bounded logs/metadata even on failure; payloads require
success. Caches, SDKs and test roots are not uploaded. These workflows do not
publish packages/releases or run project hooks. Use existing Actions entitlement;
report access/funding blockers rather than changing settings or buying runners.
Standard hosted runners can consume billable private-repository minutes.

## Native source and assembled AOT

Source policy/init, export and alias controls precede owned asset preparation,
compiler readiness/suites and genuine maintainer assembly. Setup failures and
non-native skips are not semantic results. The [shared init oracle](aot_init_assertions.dart)
requires exit 0, `ok`/`created`, correct streams/JSON and exactly two bootstrap
files for fresh-root mixed init, from foreign Unicode/spaced paths without
Dart/Node on PATH. Windows OS essentials remain available.

Both native workflows run the five compiler-backed suites serially:
`inspection_test.dart`, `typescript_references_test.dart`,
`typescript_projects_test.dart`, `dart_inspection_test.dart`, and
`input_mutations_test.dart`. Existing Linux-only chmod skips remain explicit.
Windows [file-link readiness](windows_adapter_link_readiness.dart) requires real
relative symlinks, tag/target/content checks, retargeting, cycle failure and
link-only cleanup; a junction or skip cannot substitute. Pinned runtime resolution
and actual NTFS TEMP/TMP are checked, with environment restoration in `finally`.
Counts and results come from logs, not predicted test totals.

[The assembly probe](native_assembly_init_probe.dart) invokes the real assembler,
checks fixed layout/exact owned assets, relocates the installation and runs the
shared init oracle. Profiles:

```sh
# Linux/macOS: asset and CLI process regressions, plus mixed compiler/alias checks.
dart --suppress-analytics run tool/ci/native_assembly_init_probe.dart --dart-sdk "$DART_SDK" --node "$NODE"
# Windows: real assembly, guards, relocation and init only.
dart --suppress-analytics run tool/ci/native_assembly_init_probe.dart --init-only --dart "$DART_EXE"
```

Omit both Unix runtime arguments for the asset/CLI-only profile; supply them
together and never with `--init-only`. Add `--log-directory DIRECTORY` for separate
process logs. Windows uses `tool/assemble_windows.ps1 -Output NEW_DIRECTORY -Dart
COMPILER`. Source/assembly evidence does not establish installed npm/pub routes.

## Export, transport and pack identity

Add `--artifact-directory NEW_DIRECTORY` to retain the tested installation after
all selected checks pass. Export requires a clean tracked checkout, verifies a
controlled extraction and repeats init at a fresh relocated path before exposing
`installation.tar` and external `provenance.json`.

[Export](../release/installation_artifact.dart), [transport audit](audit_installation_transports.dart)
and [native archive production](../release/build_native_archives.dart) bind exact source commit/tree, both
lock hashes, per-file bytes/sizes/modes, archive digest, actual target/runtimes and
selected suites. Tracked identity does not attest ignored tools/caches; manifests
identify the actual installation bytes. Windows transport modes do not attest
NTFS ACLs. Export alone does not certify host/filesystem or download pins.

Existing destinations (including dangling aliases), unexpected entries and
symlinks/reparse points are rejected. Extraction is exclusive into a fresh root;
failed export cleans only owned staging. The single-writer transport is not an
adversarial atomic no-replace or general untrusted-archive API.

Follow the [package workflow](../../.github/workflows/package-delivery-probe.yml)
for the native-first producer commands. It audits opaque transports before
execution, produces three native archives and one shared acquisition descriptor,
then stages thin npm/pub wrappers against that exact descriptor.
Consumers require the exact source SHA and current run ID/attempt; rerun all jobs
rather than mix attempts. Successful producer dependencies and `github.sha`
checkout establish the source relationship. Adjacent downloaded JSON alone does
not establish authenticity.

## Installed npm routes and termination limits

[The npm probe](../npm/installed_probe.dart) consumes the exact packed receipt and
tarball from [staging](../npm/stage.dart) and [packing](../npm/pack.dart). The matrix
covers local devDependency, isolated global prefix and cache-only npm exec on all
three supported targets. Installation disables scripts and uses an isolated,
offline npm cache/config. Consumers do not rebuild or repack the wrapper.

```sh
dart run tool/ci/setup_npm_wrong_node.dart --target TARGET --output WRONG_RUNTIME
dart run tool/npm/installed_probe.dart --packed-directory PACKED \
  --expected-commit COMMIT --target TARGET --route local --npm-cli NPM_CLI_JS \
  --wrong-node PREPARED_NODE_24_19 --native-archive MATCHING_NATIVE_ARCHIVE \
  --output FRESH_OUTPUT --ci-host
```

Use `global` or `cache` for the other routes. The wrong-Node preparation verifies
the official Node 24.19.0 archive; ordinary execution uses Node 24.21.0/npm 11.19.0.
`--native-archive` selects maintainer-only `ci-verified-native` preparation. The
probe authenticates descriptor/archive/manifest/executable identities before
using its exclusively owned cache. Reports explicitly retain
`public_cold_verified: false`. This does not establish public HTTPS availability;
public-cold acceptance is a separate gate after matching native assets exist.

Finalizable reports require the matching Actions source/run/attempt and actual
host. Local diagnostics or synthetic CI headers cannot replace those receipts.
Retain `WRONG_RUNTIME/runtime.json` beside the probe report before final admission;
the workflow performs this bounded projection even when the probe fails.

The real generated shim/npm-exec route exercises help/version/init, policy/export,
clean and violating TypeScript analysis, usage errors and installed asset/payload
missing/alias/corruption controls. Every invocation verifies project immutability;
mutations are restored and hash-checked. File symlink readiness is mandatory.
Cache invocations retain the 120-second npm preparation ceiling, including init
and pre-stimulus helper readiness when execution is actually through npm exec.
An explicit tarball makes npm 11.19.0 extract its manifest on every invocation.
Every installed cell has a 20-minute aggregate workflow limit. Ordinary
local/global commands retain 30 seconds; first native acquisition allows 150
seconds and wrong-Node identity allows 30. Direct/native readiness remains 15
seconds; post-stimulus termination remains five seconds. These process budgets
are checked against the original recorder evidence.

Explicit in-root corpus inclusion/exclusion applies to local installation; global
and cache report their outside-root applicability. Local/global checks repeat after
relocation without reinstall. Cache binds the selected package beneath `_npx`,
rejects fallback and proves selected payload dependence; cache relocation is not
covered. npm augments child PATH, so cache is not a Node-only child-PATH claim.

Incompatible Node must yield core `NODE_UNAVAILABLE`/2. Missing Node must fail
through the real route with no core JSON. Direct installed-native missing-Node
checks are labeled supplements. Unsupported-platform selection is fault injection,
not execution on an unsupported OS. [Shared route controls](../npm/installed_assets.dart)
and the probe retain actual exits, streams, artifact/source/run identity and host.

Termination compares a readiness-confirmed genuine native core with the route:
- POSIX shim SIGINT/SIGTERM/SIGHUP must match native streams/exits and reap the
  core. SIGINT additionally requires helper termination and the documented
  incomplete/2 `INSPECTION_CANCELLED` envelope. TERM/HUP do not claim tree cleanup.
- Cache shim signals are explicitly supplemental. Actual outer npm-exec PID
  signal failures remain recorded as an external-manager boundary. A separate
  isolated-process-group SIGINT must terminate core/helper with valid cancellation
  JSON; npm outer exit/stderr are recorded independently. This is not a PTY or
  literal terminal Ctrl-C test.
- Windows measures `TerminateProcess(core, 23)` exit propagation, not POSIX signals,
  console events or outer-process cancellation. The fixture is created suspended,
  assigned to an owned kill-on-close Job Object, then resumed. Required native
  cleanup controls cover missing/malformed readiness and assignment/resume failure.
  Nested-job restrictions fail without breakaway; cleanup waits for zero processes.

Fixture cleanup never establishes a product process-tree guarantee. Helper bytes
and readiness markers are restored/removed on failures too. See [termination
controls](../npm/installed_termination.dart); every platform still requires native
measurements. Unit checks and historical packed bytes cannot certify a new revision.

## Thin pub stage and installed snapshot

[Staging](../pub/stage.dart) regenerates the exact thin wrapper from the canonical
source and shared `acquisition.json`. It does not copy the core/analyzer or an
all-target native bundle into pub. The stage inventory binds source/tree/locks,
version, descriptor and every wrapper file. Existing outputs are refused.

```sh
dart run tool/pub/stage.dart --source SOURCE --descriptor ACQUISITION_JSON \
  --expected-commit COMMIT --output FRESH_STAGE
dart run tool/ci/pub_stage_transport.dart write --stage-evidence FRESH_STAGE \
  --source SOURCE --expected-source COMMIT --run-id RUN --run-attempt ATTEMPT \
  --output FRESH_TRANSPORT
```

The producer's successful compact JSON is an independent same-attempt input.
Pass it through an environment variable, never interpolate it into shell source
or trust an adjacent downloaded record alone. Transport contains exactly
`installation.tar` and `transport.json`; its private envelope is not a pub upload.

[SDK preparation](setup_pub_dart.dart) authenticates the official Dart 3.13.3
archive/checksum before extraction and prepares an isolated lock-enforced cache.
The CI-only bootstrap first obtains that pinned SDK so the preparation owner can
run. Reused local SDK archives still require the official digest. Preparation
retains original version, extraction and dependency commands and source identity.

```sh
dart run tool/ci/setup_pub_dart.dart --target TARGET --source SOURCE \
  --expected-commit COMMIT --output FRESH_SDK --prepare-cache --ci-host
dart run tool/ci/pub_installed_route.dart --source SOURCE --expected-source COMMIT \
  --run-id RUN --run-attempt ATTEMPT --target TARGET \
  --transport INSTALLATION_TAR --expected-json "$EXPECTED_PUB_TRANSPORT" \
  --descriptor ACQUISITION_JSON --native-archive MATCHING_NATIVE_ARCHIVE \
  --wrong-node PREPARED_NODE_24_19 --prepared-cache PREPARED_PUB_CACHE \
  --output FRESH_OUTPUT --ci-host
```

Use the prepared SDK executable for the installed command. The owner authenticates
all inputs before actual private hosted activation with `--no-executables`.
Every installed command uses `dart pub global run archway:archway`; there is no
setup executable, generated alias or launcher-repair step. The probe-owned native
cache receives only the independently pinned native artifact. No user launcher
URL override or cache-seeding option exists.

The complete original observations cover core/policy/export and TypeScript,
command/native parity, missing bridge init, helper/compiler/native/manifest
absence/alias/corruption, genuine wrong/missing Node, and SDK snapshot behavior.
Snapshot checks preserve the installed source and snapshot hashes, poison source,
exercise stale/missing snapshot failures, then restore and recheck the baseline.
Private activation uses a local hosted fixture; it is not a live pub.dev install.

Keep only `report.json`, `activation/`, `execution/`, applicable `private-export/`,
`runtime.json`, renamed original `sdk-preparation.json`, original
`sdk-preparation-execution/`, the official SDK checksum, and the bounded
`sdk-setup.log`, `runtime-setup.log` and `probe.log` diagnostics in installed
artifacts. Do not upload prepared caches, SDKs, native payloads or disposable
projects.
Readers bind every original command, exit and stream hash to the canonical source,
version, target, descriptor, transport and workflow attempt.

After changing Dart SDK, prewarm with `dart pub global run archway:archway
--version` before machine-readable commands: the SDK can print dependency/snapshot
rebuild progress on the first invocation. Warm native output is not filtered.
A genuine distinct compatible SDK switch is a separate measured release check.

### Explicit registry-candidate intent

`--registry-ready` must agree across npm/pub staging, packing/export, transport,
installed consumers and finalization. Omission selects private schema-1 pub
transport; explicit intent requires schema-2 carrying the exact SDK upload. The
private route uses SDK archive export with `--skip-validation` solely for private
qualification. It cannot substitute for registry validation.

[Registry export](../pub/export.dart) pins the official pub.dev endpoint and runs
the real SDK dry-run and archive export with separate original stdout/stderr and
exit receipts. Dart 3.13.3 must report precisely the seven reviewed tight-pin
advisories: dry-run 65, archive export 0. Unknown, missing or duplicate diagnostics
fail; no warning filtering or skip-validation applies to this route.

[Native-first finalization](finalize_native_first_release.dart) independently
regenerates the descriptor and canonical npm/pub stages, verifies complete packed
inventories, and admits all nine npm, three pub and three native host receipts.
It preserves tested archive bytes and original evidence, emits complete checksums
and publishes only into a fresh local output directory. Registry-ready metadata
and private candidate qualification do not establish public cold availability.
Publication and account actions require separate authorization.

## Release fixtures and regression checks

[Native fixture preparation](prepare_native_acceptance.dart) is a separate networked
step: `--target TARGET --output NEW_DIRECTORY`. It verifies official Flutter
3.47.4 / embedded Dart 3.13.3 and Node 24.19.0 archives, then prepares real locked
hosted collection 1.19.1, path, workspace, pinned Git `pkgs/path` and Flutter pub
projects in an isolated cache. Windows uses embedded Dart directly. Reused Flutter
archives still require byte and live official-index verification.

Pass the resulting `acceptance-fixtures.json` to
`dart --suppress-analytics run tool/ci/release_native_smoke.dart --acceptance-fixtures MANIFEST`. CI requires preparation;
missing fixtures fail instead of silently skipping coverage. Logs and readiness
hashes are retained. A development Linux preparation run is not three-host release
acceptance.

The three loopback HTTPS suites require an existing OpenSSL executable. Hosted
preparation verifies it and exports its absolute path as `ARCHWAY_TEST_OPENSSL`;
local tests use that override or `openssl` from PATH. Missing tooling fails the
tests. Each fixture generates a one-day localhost/127.0.0.1 certificate in its
owned temporary directory, loads and immediately deletes the private key, and
removes the remaining certificate at teardown. Trust is local to the fixture;
no static private key, system trust change or product dependency is required.

The release probe also runs [the complete Dart source suite](native_source_acceptance.dart)
from an exact tracked-source snapshot using the verified archive's bridge/vendor
assets. It requires every tracked `test/*_test.dart` suite, complete successful
terminal results and only the explicitly allowed host/filesystem fixture skips.
Evidence retains original Dart JSON output, source-file hashes and archive asset
identity; a reduced source selection cannot substitute for this gate.

Completed nonzero process-suite exits are collected so later isolated process
fixtures and the full source gate can still expose independent failures in the
same run. Per-suite logs/receipts and `acceptance/failures.json` retain failures;
any failure still blocks the release report and finalization. Archive-integrity
failures and suite timeouts stop immediately because shared bytes or descendant
cleanup cannot be assumed safe. Source dependency preparation remains fail-fast.


[Release finalization](finalize_native_first_release.dart) validates those source/native
receipts and every required npm/pub route against exact source, run/attempt,
transport and archive identities. It appends accepted evidence and updates
checksums without rebuilding the tested payloads; missing or mismatched receipts
block finalization.

Focused deterministic controls (distinct from genuine native route acceptance):

```sh
dart test test/package_delivery_workflow_test.dart test/package_delivery_dispatch_test.dart
dart test test/pub_stage_transport_test.dart test/pub_candidate_transport_test.dart
dart test test/release_native_input_test.dart test/release_pub_input_test.dart
dart test test/release_pub_thin_identity_test.dart test/release_pub_sdk_receipts_test.dart
```

Windows npm cells additionally require `dart run test/windows_job_capability.dart`
and the readiness suite. The capability entry refuses non-Windows execution;
a skipped platform test cannot certify this gate.

### Native installer lifecycle gate

The `release-native` matrix requires `--installer-checks`. After verifying
and extracting the immutable current-run native archive, it builds the native
unsigned `.deb`, unsigned/unnotarized `.pkg`, or per-user Inno `.exe` on its matching
host. It never downloads a compiler: `dpkg-deb` and Apple's `pkgbuild` are native
host tools; Windows must already contain official Inno Setup 6.3+ or fail clearly.
Compiler bytes and host identity, input manifest, installer bytes and original
lifecycle/installed-command logs are bound to the source/archive report.

A temporary, explicitly test-only `0.0.0` bundle adds an obsolete file; upgrade
installs the verified current-version payload and proves removal of that file. The
old test artifact is never included in the release. Linux uses an isolated dpkg
root; macOS uses native Installer and the owned shell uninstaller; Windows uses
its disposable runner account. Root-owned Unix payloads stay root-owned, while
installed policy/query/export and prepared TypeScript/Dart checks run unprivileged
from other directories. Archive checks separately cover payload corruption.

Finalization requires all three installer receipts, checks exact artifact/log
hashes and installed query/Dart suite receipts, then copies the tested installers
without rebuilding. Installer binaries remain separate release files, outside
the evidence ZIP. CLI lifecycle success does not certify downloaded-file GUI,
unsigned trust prompts, fresh desktop terminals, or Windows 11 behavior from a
Windows Server runner. Those remain separate acceptance gates.
