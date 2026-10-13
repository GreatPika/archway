# Dart inspection

Use this guide for analyzer integration, prepared pub origins, and Flutter fixtures.
Product behavior remains governed by the [requirements](../spec/requirements.md) and
[contracts](../../contracts/README.md). Inspection reads prepared projects; dependency
resolution, generators, plugins, builds and Git execution belong to preparation.

## Compiler and ownership

The baseline is Dart 3.13.3, analyzer 14.5.0, package_config 2.2.0 and
pub_semver 2.2.1. Check selects an external SDK once, verifies metadata and the
executable version, and reads SDK libraries. Project-local runtimes and aliases
to them are rejected. Each declared project owns one analyzer collection; actual
contexts supply membership and options. The pinned DriverBasedAnalysisContext,
optionsFileMap, AnalysisOptionsParseSession and FileState routes are intentional
version-specific implementation APIs. Unsupported package/file language versions
and experimental flags remain incomplete; stable Dart 2 overrides are limited to
2.12–2.19. Independent policy violations survive unsupported interpretation.

Import/export branches retain their direct physical compiler targets. Parts use
the same directed Plan predicate. URI parts need a parsed library container and
reciprocal include in every declared context; conflicting mappings cannot pick the
first owner. Named parts need a unique compatible owner found by inventorying
analyzed files and selected package libraries, then following reachable directives
to a fixed point. Discovery does not scan arbitrary disk. Its invocation-local
index stops at 100,000 files or 120 seconds; gaps and exhaustion remain incomplete
while independent facts survive.

Actual options mappings and a fresh include-graph replay through the same
SourceFactory determine context identities. Invalid graphs have no context ID.
Reads, absence, inventories and aliases join common independent revalidation.
Nonregular resources are rejected before synchronous byte reads; this prevents a
stable FIFO hang, not concurrent replacement. See [native/path safety](native-io.md).

## Prepared pub origins

The classifier joins the final physical target, selected package_config v2 and
SourceFactory mappings to target pubspec, effective workspace/override manifests
and lock evidence. The most specific library cannot borrow an enclosing self
identity. Self identity needs no ordinary dependency lock. Proven path/workspace
targets stay local outside root; proven hosted/Git targets remain external inside
broad ownership, including physical URI imports and aliases.

Explicit direct workspace members are supported. Nested or wildcard membership,
nonstandard Git HEAD/ref/config-include layouts, and file/local Git remain
incomplete. Selected overrides replace ordinary constraints; otherwise relevant
root/member dependencies and dev_dependencies must allow the installed version.
Scalar and mapping-form constraints use the locked pub_semver implementation.
Missing or contradictory metadata cannot establish an external origin.

Tests prepare hosted/path/workspace fixtures with the real offline pub resolver.
The hosted cache must already contain collection 1.19.1. The Git fixture selected
by ARCHWAY_PUB_GIT_FIXTURE contains genuine generated lock/config, a pinned checkout,
and an evidence directory with preparation commands/logs and artifact hashes.
Preparation disables hooks and analytics and runs pub get separately. Check reads
detached HEAD/origin and pub's bare-cache origin without invoking Git. SSH/git/scp
metadata derivatives test URL consistency, not additional fetched transports.
Copies preserve symlinks; isolated hosted copies replace unpublished development
lint options with an empty mapping without changing library bytes.

### Fixture provenance

- Hosted package: https://pub.dev/packages/collection/versions/1.19.1
- Archive: https://pub.dev/api/archives/collection-1.19.1.tar.gz
- Archive SHA-256 from prepared pub lock/cache: `2f5709ae4d3d59dd8f7cd309b4e023046b57d8a6c82130785d2b0e5868084e76`.
- Installed pubspec SHA-256: `0558412e31aacf6a97e6b226e0f9f6b10ab5ae95c57a8a562ff579ee1609f913`.
- BSD-3-Clause LICENSE SHA-256: `ff15faa32a2e638107b7789592b14426162a75ba620044ee2340a20ec6ce5e73`.
- Git repository: https://github.com/dart-lang/core.git
- Git fixture commit: `4d80610a878cdb3f9f10e6a16a2af6631251a3c6`; package subpath `pkgs/path`, version `1.9.2-wip`.
- Official source: https://github.com/dart-lang/core/tree/4d80610a878cdb3f9f10e6a16a2af6631251a3c6/pkgs/path
- BSD-3-Clause LICENSE SHA-256: `3c32b53167c7dae9190c38dab5dd9fe1789c53623ebc7d1babcb29914c5b3f16`.
- Git package pubspec SHA-256: `88dd9401b5dfd2bce9fae282119333b6490e342b0587a5e0a02a9e0528fb95ea`.

- pub_semver 2.2.1 archive SHA-256: `261236774e8b1d69cfc6b9eabbc96c40f25e7a2d6b171f3385d4f65d5734fb24`.

## Prepared Flutter

Select Flutter's embedded Dart SDK bin on external PATH; this route is supported
on Windows too. The ordinary Flutter bin route is unsupported on Windows. On
Linux it also selects that binary directly; check runs neither launcher nor
Flutter CLI. Runtime must report Dart 3.13.3 with stable Flutter metadata,
valid framework version/revision and engine stamp. Observed flutter.version.json
bytes/hash bind private parsed metadata; public input_identity exposes manifest
identities/hashes. This proves installation consistency, not byte authenticity.

Builtin packages must join the selected map to SDK/packages/<name>/lib or
SDK/bin/cache/pkg/<name>/lib, matching pubspec and no contradictory lock row.
Independent SDK evidence can suffice without a lock. dart:ui also needs the
selected sky_engine embedder mapping; ordinary dart: targets use the selected
FolderBasedDartSdk mapping. Other packages inherit no builtin origin.

The prepared Flutter fixture uses Flutter stable 3.47.4 with embedded Dart 3.13.3,
framework revision `9584c6713b324636289d067944a46fd6b49df14b`, SHA-256
`5b45f0ceda99b9bebdc873e7e69f6450aeb4c30f454b505e2e62fc9255a907d3`.
[Official archive index](https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json).
The fixture pubspec names flutter_fixture, requires >=3.13.0 <4.0.0, depends on
flutter from the SDK and dev-depends on flutter_test from the SDK. Prepare with
dedicated HOME/PUB_CACHE and disabled analytics before inspection.

URI parts and ordinary generated imports are covered by the prepared fixture.
Named-part discovery remains incomplete when the SDK archive omits required
internal URI or patch sources, including dart:_vm, dart:_js_helper and
sky_engine's http_profiling.dart. Plugin-dependent options remain incomplete
because inspection does not execute plugins.

## Reproduction

Run from the repository root with pinned Dart/Node on PATH, a prepared PUB_CACHE,
Python jsonschema, native bridge and trusted TypeScript assets. Set DART_SDK to
the SDK root, NODE to its absolute executable, ARCHWAY_PUB_GIT_FIXTURE to the
prepared Git fixture, and optional ARCHWAY_FLUTTER_FIXTURE to its prepared project.
The following AOT process commands are Linux host checks:

```sh
# Preparation, separate from check; requires already cached dependencies.
dart --suppress-analytics pub get --offline
sh tool/build_native.sh
dart --suppress-analytics analyze lib test
dart --suppress-analytics test --concurrency=1
sh tool/assemble.sh build/install
python3 test/dart_check_process_smoke.py build/install/bin/linux-x64/archway "$DART_SDK" "$NODE"
python3 test/dart_resource_process_smoke.py build/install/bin/linux-x64/archway "$DART_SDK"
python3 test/prepare_package_process_pub.py "$PREPARED_PUB" "$DART_SDK/bin/dart"
python3 test/package_provenance_process_smoke.py build/install/bin/linux-x64/archway "$PWD" "$PREPARED_PUB" "$ARCHWAY_PUB_GIT_FIXTURE" "$OUTPUT"
```

PREPARED_PUB and OUTPUT are fresh directories. For the optional Flutter process
check, set both FLUTTER_SDK to the prepared SDK root and ARCHWAY_FLUTTER_FIXTURE
to its prepared project, then run:

```sh
python3 test/dart_flutter_process_smoke.py build/install/bin/linux-x64/archway "$FLUTTER_SDK" "$ARCHWAY_FLUTTER_FIXTURE"
```

The Flutter process fixture creates a hardlinked copy on that filesystem
and unlinks before edits, leaving the installed SDK unchanged. Process fixtures
check public JSON/schema, exit/streams, relocation, runtime failures and retained
independent violations. Source tests also cover per-file language versions,
workspace overrides, origin metadata mutations and part ambiguity.

These commands exercise Linux development-host cases; they do not certify clean
Ubuntu, other platforms or installation routes. Socket cases may skip when host
binding is prohibited. ARCHWAY_SYSCALL_TRACE=1 requests Linux syscall assertions;
only a successful trace establishes those assertions for that run. See the
[CI guide](../../tool/ci/README.md) for current coverage.
