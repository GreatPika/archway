# Installation and package staging

The [delivery contract](../../contracts/compatibility/delivery.md) defines the
0.2.0 preview design. Thin wrapper production and hosted installation are not yet
certified. Published 0.1.0 artifacts remain unchanged; see the
[release page](https://github.com/GreatPika/archway/releases) for actual availability.
Default stages are private. Staging does not publish or establish target acceptance.

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
SDK plus the verified native cache. SDK-switch and missing/stale-snapshot behavior,
including SDK recompilation or network use, must be measured separately. Do not
present an unmeasured or unpublished package as available. The
[package guide](../../tool/npm/README.md) describes the intended user boundary.

Retain Archway's [MIT license](../../LICENSE), required dependency notices and
exact inventories in their owning artifacts. Default source/developer stages
remain private. Registry-ready metadata is an explicit staging choice made before
hashing and validation, never a post-test edit. Staging does not authenticate,
publish, reserve a name or certify a route.

## Reproduce bounded acceptance

Python process checks require jsonschema, pinned runtimes and prepared caches.
The [CI guide](../../tool/ci/README.md) records existing 0.1.0 source/AOT/transport
fixtures; those bundled-package and pub snapshot results are historical route
evidence, not acceptance of the new thin wrappers.

The 0.2.0 gates run real packed npm local/global/cache commands and installed pub
commands. Private injected transport/cache/extraction fixtures exercise download
bounds, redirects, invalid archives, interruption, concurrent publication and
corruption refusal. Include offline warm use, another cwd, spaces/Unicode,
unsupported targets, actual native writes, runtime failures, arguments/streams/
exits and artifact inventory identity. Preserve all native compiler/platform
checks from the delivery contract.

A genuine private hosted Linux fixture with Dart 3.13.3 passes no-executables
activation and explicit global run: exact argv/streams/exit 37, no execution-time
HTTP, and offline operation with the server stopped. Poisoned still-present source
continues to dispatch the prepared snapshot. This is bounded SDK-route evidence;
the actual thin-wrapper fixture also measured a switch from Dart 3.13.3 to 3.13.5.
The first switched invocation printed SDK dependency-resolution progress before
native stdout; warm and offline invocations preserved native streams. No requests
reached the live fixture registry during that switch, which is not a general
no-network guarantee. After an SDK change, prewarm with
`dart pub global run archway:archway --version` before capturing JSON.
Actual Archway thin-wrapper runs on all three platforms remain required. Native uploads require
separate authorization, then actual pinned hosted-URL cold fetch must pass before
separately authorized registry publication. Local tests are not hosted download
or registry certification. Windows Server evidence does not certify Windows 11,
and assembly success does not certify downloaded desktop installation.
