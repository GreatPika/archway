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

Use the workflow's pinned Python/PyYAML/jsonschema setup for the selected probe.
Windows assembly requires native Python 3.9+, PowerShell, explicit pinned Dart,
and verified Git for Windows Bash with pinned Node/npm first on PATH. Windows
init-only needs no jsonschema. Source policy/init controls need no Node.

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
non-native skips are not semantic results. The [shared init oracle](aot_init_assertions.py)
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
and [combination](combine_installations.py) bind exact source commit/tree, both
lock hashes, per-file bytes/sizes/modes, archive digest, actual target/runtimes and
selected suites. Tracked identity does not attest ignored tools/caches; manifests
identify the actual installation bytes. Windows transport modes do not attest
NTFS ACLs. Export alone does not certify host/filesystem or download pins.

Existing destinations (including dangling aliases), unexpected entries and
symlinks/reparse points are rejected. Extraction is exclusive into a fresh root;
failed export cleans only owned staging. The single-writer transport is not an
adversarial atomic no-replace or general untrusted-archive API.

Follow the [package workflow](../../.github/workflows/package-delivery-probe.yml)
for the audit/combine/pack commands. It audits opaque transports before execution,
then produces one all-target npm tarball with scripts disabled and offline mode.
Consumers require the exact source SHA and current run ID/attempt; rerun all jobs
rather than mix attempts. Successful producer dependencies and `github.sha`
checkout establish the source relationship. Adjacent downloaded JSON alone does
not establish authenticity.

## Standalone private Linux npm smoke

[The private packaging smoke](../../test/package_delivery_process_smoke.py) takes
an existing Linux-x64-only installation prepared by the
[maintainer assembler](../../docs/implementation/installation-layout.md#prepare-and-assemble),
including its real native executable, bridge and owned TypeScript assets. On
Linux x64/glibc, with Python `jsonschema` and Node 24.21.0/npm 11.19.0 on PATH,
pass that installation and a separately prepared Node 24.19.0 executable:

```sh
python3 test/package_delivery_process_smoke.py PREPARED_LINUX_INSTALLATION PREPARED_NODE_24_19
```

It stages and installs a private package into temporary local/global/cache routes
and checks rejection of the incomplete all-target input. This is a standalone
Linux bundled-package regression, not acceptance of the 0.2.0 thin wrappers.

## Installed npm routes and termination limits

[The npm probe](npm_local_install_probe.py) takes one verified tarball, checks its
filename/length/SHA-256 and installed manifest, and runs all nine native OS/route
cells: local devDependency, isolated global prefix and cache-only npm exec.
Consumers never rebuild, repack or manually extract it. Each uses scripts-disabled,
offline installation, isolated cache/config and an unreachable registry.

The standalone command below is diagnostic, not release evidence. Finalizable
reports require the matching Actions consumer job's `GITHUB_SHA`, `GITHUB_RUN_ID`
and `GITHUB_RUN_ATTEMPT`; omitted identity fields are null and rejected at finalization.

```sh
python3 tool/ci/npm_local_install_probe.py --packed-directory PACKED --target TARGET \
  --route local --wrong-node PREPARED_NODE_24_19 --runner-label RUNNER --report REPORT
```

Use `global` or `cache` for the other routes. [Wrong-Node preparation](setup_npm_wrong_node.py)
verifies official Node 24.19.0 separately; normal launchers remain on
Node 24.21.0/npm 11.19.0. Reports require the negative runtime and its digest.

The real generated shim/npm-exec route exercises help/version/init, policy/export,
clean and violating TypeScript analysis, usage errors and installed asset/payload
missing/alias/corruption controls. Every invocation verifies project immutability;
mutations are restored and hash-checked. File symlink readiness is mandatory.
Cache invocations retain the 120-second npm preparation ceiling, including init
and pre-stimulus helper readiness when execution is actually through npm exec.
An explicit tarball makes npm 11.19.0 extract its manifest on every invocation.
Windows-cache alone has a 20-minute aggregate job limit for its 33 npm-exec invocations, setup and fixture
checks. Other cells retain ten minutes. Direct/native readiness remains 15 seconds;
post-stimulus termination remains five seconds. No correctness assertion is relaxed.

Explicit in-root corpus inclusion/exclusion applies to local installation; global
and cache report their outside-root applicability. Local/global checks repeat after
relocation without reinstall. Cache binds the selected package beneath `_npx`,
rejects fallback and proves selected payload dependence; cache relocation is not
covered. npm augments child PATH, so cache is not a Node-only child-PATH claim.

Incompatible Node must yield core `NODE_UNAVAILABLE`/2. Missing Node must fail
through the real route with no core JSON. Direct installed-native missing-Node
checks are labeled supplements. Unsupported-platform selection is fault injection,
not execution on an unsupported OS. [Shared route controls](npm_installed_acceptance.py)
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
controls](npm_termination_controls.py); every platform still requires native
measurements. Unit checks and historical packed bytes cannot certify a new revision.

## Private pub stage and installed snapshot

The [file-set gate](../../test/pub_package_process_smoke.py) needs the clean exact
source that produced the three original transports and their combined result:

```sh
python3 test/pub_package_process_smoke.py "$DART" "$SOURCE" "$COMBINED" \
  "$TRANSPORTS" "$EXPECTED_SOURCE_COMMIT" "$NEW_EVIDENCE_DIRECTORY"
```

It binds source/tree/locks and native/shared assets, compares the exact private
all-target stage inventory to pub's `--dry-run --skip-validation` listing and
rejects subsequent drift. This proves file-set inclusion, not emitted pub archive
bytes, publication readiness, hosted installation or activation.

The Linux producer then runs the [stage identity controls](../../test/pub_stage_identity_test.py)
against that genuine stage before writing its transport. They reject partial,
target and privacy manifest edits, missing native bridges, altered
source/license/schema/pubspec, extra entries, source aliases and wrong commits.
They restore each change and recheck the valid stage.
The transport writer requires the restored inventory to match the original
stage identity and dry-run report. Any control failure stops transport production;
`build/pub-producer/identity-controls.log` is retained even on failure.

[The snapshot probe](pub_snapshot_probe.py) consumes that persisted evidence:

```sh
python3 tool/ci/pub_snapshot_probe.py --dart "$DART" --node "$NODE" \
  --stage-evidence "$STAGE_EVIDENCE" --source "$SOURCE" --combined "$COMBINED" \
  --transports "$TRANSPORTS" --expected-source "$EXPECTED_SOURCE_COMMIT" \
  --expected-digest "$STAGE_DIGEST" --prepared-cache "$PREPARED_CACHE" \
  --target "$TARGET" --output "$NEW_SPACE_FREE_DIRECTORY"
```

The caller independently binds source/digest. The source checkout may differ from
the harness checkout; never substitute a newer harness commit for artifact identity.
The probe verifies original source/transports, stages a disposable Unicode/spaced
Git fixture and activates using an isolated lock-matched cache. Git user config,
hooks/signing/templates are disabled. Dart 3.13.3 Git activation requires official
pub.dev metadata: it is not offline installation. Archive requests or changed
prepared dependencies fail; resolution logs/hashes and the fixture commit survive.

The probe explicitly runs `dart pub global run archway:setup` before invoking the
installed launcher with Dart and required launcher tools but no Node. It repeats
help/version/shared init after removing the disposable Git source and poisoning
the still-present installed `bin/archway.dart`. A direct-source failure control and
successful pub global run establish snapshot use without an invalid file-removal
oracle. Policy/export, real TypeScript with pinned Node, missing Node, helper
aliases/decoys and bridge failures are checked afterward. Generated and repaired
launcher hashes are recorded separately; repaired launcher/snapshot hashes remain
unchanged during inspection. Dead-loopback runtime proxies are not an OS sandbox.

PUB_CACHE includes spaces/Unicode. The [analysis smoke](../../test/pub_snapshot_analysis_process_smoke.py)
also verifies repeat setup and reactivation regenerating the SDK launcher before
setup restores the repair. Unknown launcher templates are rejected unchanged.
This gate covers isolated Git activation/snapshots, not hosted or dependency-local
installation. Reports preserve actual host/edition; Linux cloud or Windows Server
results cannot certify a different required OS or source revision.

### Same-run pub transport

By default, [the transport writer/reader](pub_stage_transport.py) carries the verified
stage and identity/report, never the full native transports/combined installation.
Its gzip/tar is private transport, not a pub-generated archive. The successful
producer's compact JSON output binds source/tree/locks, stage digest, archive
SHA/size and exact run ID/attempt. Pass it through an environment variable, never
interpolate JSON into shell source or trust an adjacent download by itself.

For the snapshot transport route, replace local `--stage-evidence`, `--combined`,
`--transports` and `--expected-digest` with `--transport-archive`,
`--expected-transport-json`, `--run-id` and `--run-attempt`. Keep explicit
`--expected-source` plus runtime/source/cache/target/output arguments. Consumers
verify current SHA/run/attempt and clean checkout, bound archive/member sizes,
reject noncanonical/alias entries and revalidate exact extracted bytes/inventory.
Cross-host identity uses bytes/sizes rather than requiring Unix modes on Windows.
Reports retain both the transport record and extraction receipt.

### Explicit registry-candidate intent

`--registry-ready` must match across staging, packed verification, release wrapping,
`pub_package_process_smoke.py`, pub identity controls, transport writer/reader,
`npm_local_install_probe.py`, `pub_snapshot_probe.py` and finalization. Omission
preserves private metadata and schema-1 receipts; mismatched intent is refused.
Candidate pub snapshot checks require authenticated schema-2 archive transport,
not the local-stage shortcut. The outer envelope carries the sole pub-exported
`pub-package.tar.gz` plus stage identity/report; consumers verify and extract those
exact archive bytes before the existing Git activation and snapshot checks.

Candidate validation retains full dry-run/export logs and raw statuses. The
pinned validator must report precisely the seven reviewed tight-pin advisories:
dry-run exits 65 and separate archive export exits 0. This means validated with
seven expected advisories, not zero warnings. Unknown, missing or duplicate
advisories fail. No skip-validation or ignore-warnings option applies.

Candidate finalization requires matching installed receipts, including the exact
pub upload-archive identity, and still checks every native installer receipt.
It does not rebuild payloads. Offline intent and synthetic transport tests do not
establish real package export or hosted installation. Publication and account
actions require separate authorization.

## Release fixtures and regression checks

[Native fixture preparation](prepare_native_acceptance.py) is a separate networked
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


[Release finalization](finalize_release_evidence.dart) validates those source/native
receipts and every required npm/pub route against exact source, run/attempt,
transport and archive identities. It appends accepted evidence and updates
checksums without rebuilding the tested payloads; missing or mismatched receipts
block finalization.

Focused deterministic controls (distinct from genuine native route acceptance):

```sh
python3 test/native_export_workflow_test.py
python3 test/package_delivery_workflow_test.py
python3 test/installation_artifact_test.py
python3 test/npm_local_install_probe_test.py
python3 test/npm_local_analysis_test.py
python3 test/npm_cache_exec_test.py
python3 test/pub_snapshot_workflow_test.py
python3 test/pub_snapshot_probe_test.py
python3 test/pub_snapshot_launch_test.py
```

### Native installer lifecycle gate

The `release-native` matrix requires `--installer-checks`. After verifying
and extracting the immutable current-run native archive, it builds the native
unsigned `.deb`, unsigned/unnotarized `.pkg`, or per-user Inno `.exe` on its matching
host. It never downloads a compiler: `dpkg-deb` and Apple's `pkgbuild` are native
host tools; Windows must already contain official Inno Setup 6.3+ or fail clearly.
Compiler bytes and host identity, input manifest, installer bytes and original
lifecycle/installed-command logs are bound to the source/archive report.

A temporary, explicitly test-only `0.0.0` bundle adds an obsolete file; upgrade
installs the exact `0.1.0` verified payload and proves removal of that file. The
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
