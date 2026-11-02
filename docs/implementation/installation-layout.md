# Standard Dart installation and native assets

The root pubspec declares the `archway` executable. Dart SDK 3.13.3 owns Git
package resolution, build hooks, AOT bundling, install/update and uninstall. Use
the single command in the [delivery contract](../../contracts/compatibility/delivery.md).
There is no Archway-specific installer, wrapper, download cache or startup repair.

`hook/build.dart` selects a package-contained ABI-2 bridge for Linux x64,
macOS arm64 or Windows x64 and registers it as a dynamically bundled code asset.
The hook never invokes a compiler or network request. The FFI owner uses the same
asset ID, `package:archway/src/native/native_io.dart`; it does not locate assets
via cwd, project package metadata, upward search or source checkout paths.

Dart places the selected asset with the installed executable. Tests must use
that real installed bundle rather than inventing a source-only layout. Test-only
bundle copies may remove/replace the bridge to prove fail-closed behavior; no
production path/environment override is introduced.

Keep C sources and platform build scripts for maintainers. Rebuilding a bridge
is a deliberate development operation requiring that platform's compiler, not an
end-user installation prerequisite. Track packaged bytes and source provenance;
changing a bundled binary requires the corresponding ABI/fault/platform checks.

Native writes and raw alias reads retain the [native I/O contract](native-io.md).
Source execution and installed execution use the same Dart code. Inspection
requires an external prepared Dart SDK and never executes project wrappers,
installs dependencies, runs generators or downloads an SDK.

`native/assets.json` records the three asset hashes and seven source/build-script
hashes. Run `dart tool/verify_native_assets.dart` to check them. Maintainer
builds should write to a separate `build/...` directory, not overwrite tracked
assets accidentally; an intentional asset update also refreshes provenance and
reruns the appropriate target acceptance. Per-asset `origin` records identify the
historical release or CI build and its inputs. Historical archives, commits and
run links may no longer be available after the initial-release reset; these
receipts are not current download locations. Installation uses only the bundled
bytes and does not fetch old releases. The top-level source hashes describe
the current maintained inputs, not a claim that every asset was rebuilt. The
read-only macOS maintainer workflow uploads a source-bound bridge and receipt;
it does not update the branch. Importing that artifact requires separate review
and an actual SDK installation test on macOS.

## Installation trust boundary

The explicitly invoked SDK installation is trusted, not a sandbox against someone
who can modify its executable or bundled library. A symbolic link to the installed bridge, or its library-directory ancestor,
follows standard SDK loading semantics. This does **not** relax project corpus, output, external-runtime,
raw-link or same-handle/no-follow filesystem rules.

The SDK must use the registered installed asset, never a library found in the
current directory or inspected project. Regression tests place corrupt decoys at
both `cwd/lib/<library>` and `<project>/lib/<library>` and still require correct
output; valid decoys must not rescue a missing installed asset. Missing symbols,
wrong ABI and missing installed assets remain fail-closed before output writes.
