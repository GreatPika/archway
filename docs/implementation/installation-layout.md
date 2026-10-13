# Installation and package staging

Use this guide for owned asset lookup, maintainer assembly and package staging.
The [delivery contract](../../contracts/compatibility/delivery.md) defines acceptance;
implemented assembly and isolated fixture passes do not establish release readiness.
The 0.1.0 preview distribution format is downloadable GitHub release assets; see
the [installation instructions](../../README.md#get-archway) for availability.
Default developer npm stages retain private: true and pub stages retain
publish_to: none. Neither registry package is published, and staging does not
establish release availability or platform acceptance.

## Layout and trust boundary

Source execution and pub snapshots resolve Archway's own package URI. Maintainer
assembly selects native mode explicitly. Native executables live under `bin/<target>`,
bridges under `native/<target>`, and shared helper/compiler files under assets.
Canonical targets are linux-x64, macos-arm64 and windows-x64; Node darwin/arm64 maps
to macos-arm64. There is no cwd, project compiler or source/native fallback.

The layout owner uses dart:io without a native-loader cycle. Bridge/helper consumers
recheck ordinary canonical files before use. The npm launcher validates the chosen
native payload against its ordinary canonical manifest before direct spawn with
inherited streams and unchanged argv. This prevents fallback to interpreting an
invalid native payload as a script. It detects ordinary corruption, not malicious
manifest-and-payload replacement or concurrent races. Prelaunch failure uses stderr/exit 126, outside
core JSON. No CLI command consumes stdin; the wrapper inherits it unchanged.

## Prepare and assemble

Run from repository root with Dart 3.13.3, Node 24.21.0, npm 11.19.0 and prepared
Dart dependencies. TypeScript 5.9.3/yaml 2.8.1 assets are prepared separately by
[the owned helper procedure](../../assets/typescript/README.md); that preparation
can fetch dependencies. Assembly compiles owned sources, never inspected projects.
Fresh destinations are mandatory. Linux requires x64/glibc and a C compiler;
macOS requires native arm64 and Apple compiler/SDK tools; Windows requires native
x64, PowerShell and the configured Visual Studio/Windows SDK build tools.

```sh
# Linux x64 or macOS arm64; use a fresh destination.
bash tool/prepare_typescript.sh
sh tool/assemble.sh build/install
```

On Windows, prepare the same owned assets first, then run PowerShell with absolute
paths: tool/assemble_windows.ps1 -Output <fresh installation> -Dart <pinned dart.exe>.
Unix assembly selects its host builder; Windows verifies the supplied compiler.
Successful assembly alone does not satisfy the delivery acceptance matrix.
The [CI guide](../../tool/ci/README.md) describes source/AOT/transport and installation
probes and their actual scope. Windows Server evidence cannot certify Windows 11.

## Stage packages

The existing assembler owns both channels. npm stages native binaries, bridges
and shared assets; pub stages source, bridges and shared assets. Both include
schemas, the [package guide](../../tool/npm/README.md), versions/file hashes, the
[Archway MIT License](../../LICENSE) and original dependency notices. The required pnpm MIT and yaml ISC notices and
vendor trees are retained unchanged; their licenses do not license Archway.
Aliased/nonordinary input trees and missing required notices are rejected.

For Linux-only development staging:

```sh
sh tool/assemble.sh npm-private-linux build/private-npm build/install
(cd build/private-npm && npm pack --ignore-scripts --offline --json)
sh tool/assemble.sh pub-private-linux /tmp/archway-private-pub build/install
```

Use a fresh standalone pub destination outside ignored Git parents: ignored stages
can yield empty publish-filter listings. All-target modes are `npm` and `pub`
without the suffix; they require every target's real required files, never dummy
payloads. npm requires three native executables and bridges; pub requires three
bridges alongside source. Combined artifact provenance/byte verification remains
separate from individual host assembly. Staging never publishes or reserves names.

### Prepare registry metadata explicitly

For a complete, audited all-target installation, the staging command also accepts
an explicit metadata opt-in:

```sh
sh tool/assemble.sh npm build/registry-npm build/combined-installation --registry-ready
sh tool/assemble.sh pub /tmp/archway-registry-pub build/combined-installation --registry-ready
```

This creates publication-capable metadata before hashing. The root checkout stays
private, and partial stages are rejected. Both channels include the same package
guide, changelog and license. These commands do not publish or reserve names.
The existing private acceptance pipeline does not certify these candidates yet;
full validation, exact upload-archive tests and hosted installation evidence are
separate gates. Do not edit private metadata after an artifact has been tested.

The same explicit intent must reach packed verification, release wrapping,
installed npm probes, authenticated pub transport/snapshot probes and finalization.
Candidate pub probes consume the single exported archive through schema-2
transport; they cannot substitute an independently prepared stage. Default
private invocations remain unchanged. See the [CI guide](../../tool/ci/README.md#explicit-registry-candidate-intent)
for the exact validation advisory policy and receipt boundary. Offline wiring
tests do not establish real archive export, registry or installed-route acceptance.

## Reproduce bounded acceptance

Python process checks need jsonschema, real pinned runtimes and prepared caches.
On Linux, build a fresh installation, set NODE/DART to absolute executables,
WRONG_NODE to a genuine incompatible Node, and run:

```sh
python3 test/native_asset_process_smoke.py build/install/bin/linux-x64/archway
python3 test/check_process_smoke.py build/install/bin/linux-x64/archway "$NODE"
python3 test/package_delivery_process_smoke.py build/install "$WRONG_NODE"
python3 test/pub_snapshot_analysis_process_smoke.py "$DART" "$NODE" "$PUB_CACHE"
```

The npm process fixture tests actual offline/script-disabled pack, local/global/
cache routes, relocation, corruption, runtime failures and Linux signal parity.
Cache-payload removal verifies that npm exec used its cache. Linux signal parity
is not a Windows/macOS termination guarantee or product process-tree cleanup.
For the executable pub command and exact-source/three-transport prerequisites,
follow the [private all-target pub file-set gate](../../tool/ci/README.md#private-pub-stage-and-installed-snapshot).
Its dry-run listing with validators skipped proves file-set inclusion, not emitted
archive bytes, publication readiness, activation or hosted installation.

The pub snapshot fixture activates a local Git source in an isolated prepared
cache, verifies asset bytes and explicitly runs installation setup. It removes the
original source and poisons the still-present cached entrypoint. Direct source
execution must fail while the installed launcher and explicit pub global run use
the generated snapshot. Removing the cached entrypoint is not a valid oracle for
pub global run, which checks that the file exists before snapshot dispatch.
This proves that bounded route, not hosted-registry or dependency-local dart run.
Dart global activation has no offline flag here and may fetch public dependency
metadata. Fixture preparation and activation are separate from inspection.

## Explicit pub launcher setup

After every pub global activation or update, run:

```sh
dart pub global run archway:setup
archway --version
```

Use the same Dart SDK and PUB_CACHE as activation, with its bin directory on PATH.
The complete supported pub route includes this explicit setup step. No hosted
package is currently published; the sequence also applies to the separately
verified local Git activation fixture. Setup is not part of ordinary CLI startup.

Dart 3.13.3 generates an unquoted POSIX snapshot existence test. In a spaced cache,
stock activation alone produces a shell diagnostic before Archway starts, even
when pub subsequently runs its snapshot successfully. Setup verifies the complete
known SDK launcher, the active package identity and canonical file paths, then
atomically replaces only Archway's launcher with literal-quoted snapshot paths.
It preserves file modes, argument forwarding, exit codes and SDK stale-snapshot
fallback. It never changes the SDK, project files or another package's launcher.
Already repaired launchers are left byte-for-byte unchanged. Unknown templates
and aliases fail unchanged. On Windows, setup recognizes the exact pinned batch
launcher and replaces its final fallthrough with explicit exit-status propagation
for both snapshot and pub fallback branches. It preserves the original system
encoding and rejects a replacement that would change the file mode. Recognized
path-activation launchers remain no-write no-ops. Reactivation regenerates the SDK launcher, so rerun setup afterward;
a different SDK template must be reviewed before support is claimed.

Process tests cover a spaced/Unicode cache, repeat setup, reactivation and
poisoned-source snapshot controls. The cross-platform gate also uses a spaced
cache and records generated and post-setup launcher hashes. These checks do not
establish hosted installation or acceptance on unmeasured targets.
Upstream pinned implementation: [launcher creation and refresh](https://github.com/dart-lang/pub/blob/ec276d10a7fa0f6c6ec005340fb9ad29f3b012d0/lib/src/global_packages.dart#L779-L1003).

Release claims require current exact-source platform, installation-route,
artifact and license evidence. See the [CI guide](../../tool/ci/README.md) for
acceptance gates and the [installation instructions](../../README.md#get-archway)
for release availability.
