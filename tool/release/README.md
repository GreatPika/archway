# Native-first archive production

Produce native archives independently of npm/pub staging:

```sh
dart run tool/release/build_native_archives.dart \
  --source /path/to/clean-source-with-prepared-typescript-assets \
  --expected-commit FULL_SOURCE_COMMIT \
  --transports /path/to/transports \
  --guide /path/to/tool/release/QUICKSTART.txt \
  --output /path/to/new-native-output
```

The source checkout must have clean tracked files and the assembler's prepared,
pinned TypeScript/yaml vendor assets. The producer does not build native code,
prepare dependencies, stage wrappers, or publish releases. It reuses original
same-source transports from all three supported targets and the existing
assembly inventory checks. Each transport directory contains installation.tar
and provenance.json. Original byte-for-byte copies and the transport audit are
retained under evidence/.

Output contains archway-VERSION-TARGET.tar.gz (Linux/macOS) or .zip (Windows),
plus native-packaging.json. The receipt binds version/source to each archive's
filename, byte size, SHA-256, root-manifest SHA-256, original transport identity
and added-file inventory. It is a native-production receipt for descriptor
production and final aggregation, not the final combined release receipt.
Archive roots and manifest fields preserve the existing native release layout.
The output appears only after all archive inventories and source identity pass
verification; existing destinations are never replaced.

Version comes from pubspec.yaml; exact Dart/Node versions come from matching
transport runtime evidence, with Dart checked against the SDK compatibility
constraint. TypeScript/yaml pins come from the source lock and are compared with
actual prepared vendor metadata. No wrapper manifest supplies native metadata.

`dart test test/native_archive_producer_test.dart` exercises physical synthetic
transport inputs, deterministic archive bytes and refused inputs. These fixtures
do not certify executable payloads or any target host. Genuine hosted archive
extraction/execution remains the separate native qualification gate below.

## Final archive CI gate

Run [the package-delivery workflow](../../.github/workflows/package-delivery-probe.yml)
with `workflow_dispatch` at the exact final source commit. Its `release-native`
job extracts and executes the prepared native archives on Ubuntu 24.04 x64,
macOS 15 arm64, and Windows Server 2025 x64 via
[`release_native_smoke.dart`](../ci/release_native_smoke.dart). The `release-finalize`
job requires those jobs plus the npm and pub installed-route matrices, binds
receipts to the source/run and tested artifacts, and retains `release-ready`
files without rebuilding the tested native archives or publishing them.
Inspect the actual run and retained reports before treating any gate as passed;
workflow wiring and local tests alone do not establish target-host acceptance.
