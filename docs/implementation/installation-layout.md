# Installation and package staging

The [delivery contract](../../contracts/compatibility/delivery.md) defines the
0.2.0 preview package layout. See the
[release page](https://github.com/GreatPika/archway/releases) for available artifacts
and registry installation instructions. Use registry packages only when the
selected release lists them as published. Default stages are private; staging
does not publish packages or establish installation acceptance.

## Layout and trust boundary

Core source development resolves Archway's own package URI; native assembly uses
explicit native mode. Native executables stay under bin/<target>, bridges under
native/<target> and compiler/helper assets under assets/. Targets remain linux-x64,
macos-arm64 and windows-x64. No cwd/project compiler or source/native fallback exists.
The explicitly invoked installation may be inside the inspected root without
silently changing the user's scope/exclude policy.

The thin npm JavaScript launcher and separate tool/pub Dart launcher consume one
generated release descriptor. Each uses its own OS-user cache keyed by version,
target and digest. First invocation acquires one target over bounded HTTPS;
`archway --version` may prewarm it; for pub use
`dart pub global run archway:archway --version`. Extraction validates archive size/hash, safe
ordinary entries and the pinned manifest's full inventory before atomic publication.
A concurrent winner must also validate. Existing corrupt cache entries fail closed;
there is no automatic deletion, updater, garbage collection or public URL override.

Warm launch verifies the pinned manifest and executable hashes, then directly
spawns the native core with inherited streams and unchanged arguments. Other
assets retain the core's canonical-path/runtime checks, not full warm digest
verification. Prelaunch errors go to stderr with exit 126, outside core JSON.
Hashes detect corruption and identify artifact bytes; they are not a signature or
protection from same-user tampering. Measure signal behavior separately on each OS.

### Windows executable path limit

The pinned Dart 3.13.3 native runtime uses a 261-byte UTF-8 buffer, including
the terminating NUL, to locate its executable. Longer canonical paths can fail
before Archway starts with an AOT-snapshot error. Unicode may use multiple bytes
per character. A same-byte Windows fixture failed at 262 bytes and passed at 244;
tested npm cache routes passed, but arbitrary deeply nested paths are unsupported.
See the [Dart startup implementation](https://github.com/dart-lang/sdk/blob/3.13.3/runtime/bin/main_impl.cc#L1104-L1107).

## Prepare and assemble

Use Dart 3.13.3, Node 24.21.0/npm 11.19.0 and prepared Dart dependencies. Prepare
TypeScript 5.9.3/yaml 2.8.1 through the [owned helper procedure](../../assets/typescript/README.md).
Build-time preparation may fetch dependencies; inspection never does. Fresh
assembly destinations are required.

```sh
bash tool/prepare_typescript.sh
sh tool/assemble.sh build/install
```

Linux requires x64/glibc and a C compiler; macOS requires native arm64 and Apple
SDK/compiler tools. Windows uses tool/assemble_windows.ps1 with an absolute fresh
Output path and pinned Dart executable, plus configured Visual Studio/Windows SDK
build tools. The core entrypoint remains bin/archway.dart. Native assembly retains
one owner; wrapper packaging does not implement another native assembler.

## Stage packages

For 0.2.0, build native archives first, derive the shared pinned descriptor from
their exact bytes, and only then stage the npm/pub wrappers. The descriptor records
release/source identity, target, immutable HTTPS archive URL, exact byte size and
SHA-256, and root-manifest SHA-256. Native production must not depend on an npm
manifest. Final aggregation consumes the independently built artifacts.

Wrapper packages no longer contain all native payloads or the core/analyzer
source tree. The pub launcher is staged separately from tool/pub. Install it with
`dart pub global activate --no-executables archway VERSION`, then invoke
`dart pub global run archway:archway <args>` using pinned Dart 3.13.3. Native/npm
retain plain archway. Pub needs the SDK for activation and every invocation;
no generated alias, launcher rewrite or setup/repair command belongs to this route.
Offline pub invocation requires its prepared activated snapshot under the same
SDK plus the verified native cache. SDK switches or missing/stale snapshots can
trigger SDK recompilation and network use. The
[package guide](../../tool/npm/README.md) describes installation and usage.

Retain Archway's [MIT license](../../LICENSE), required dependency notices and
exact inventories in their owning artifacts. Default source/developer stages
remain private. Registry-ready metadata is an explicit staging choice made before
hashing and validation, never a post-test edit. Staging does not authenticate,
publish, reserve a name or certify a route.

## Platform verification

Portable bundles, automated installer scenarios, npm local/global/cache and pub
global-run routes were tested in CI on Ubuntu 24.04 x64, macOS 15 arm64 and
Windows Server 2025 x64. See the
[CI guide](../../tool/ci/README.md) for test procedures and process limitations.

Pub offline use requires the prepared activated snapshot under the same SDK and
the verified native cache. After an SDK change, prewarm with
`dart pub global run archway:archway --version` before capturing JSON: the SDK can
print dependency-resolution progress while preparing its snapshot. This step
may require network access.

CI installation tests do not establish public download or registry availability.
Consult the release notes for public-download verification and published packages.
Windows 11 and downloaded-file GUI installation on the target desktops have not
been verified. Installers are unsigned, and the macOS installer is not notarized.
