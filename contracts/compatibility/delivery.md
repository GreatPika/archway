# Dart package delivery contract

Archway 0.1.0 is a Dart-only executable package distributed as a qualified
preview. Policy and public schema versions are 1. This initial release uses one
root commit and one version tag; historical release names do not define its
behavior. The package is not published to pub.dev (`publish_to: none`).

## One installation route

Current unreleased source requires Dart SDK 3.13.5. The published v0.1.0 tag
retains its Dart SDK 3.13.3 requirement and installation command:

```sh
dart install 'archway@{git: {url: https://github.com/GreatPika/archway.git, ref: v0.1.0}}'
archway --help
```

The actual SDK accepts a pubspec Git descriptor; a URL followed by `--git-ref` is
not its command grammar. Dart owns dependency resolution, native-asset bundling,
installation location and generated command. If needed, follow its printed PATH
instruction. Repeating this command reinstalls the pinned version; choose a later release
tag explicitly to update;
`dart uninstall archway` removes it. Installation may access Git/package hosts;
inspection never performs downloads or dependency preparation.

There is no custom archive acquisition/cache protocol, npm/pub wrapper,
self-updater or compiler-on-install step. Do not advertise a bare pub.dev package
name until separately authorized publication has actually happened. Git branch
publication and registry publication are distinct actions.

## Bundled filesystem assets

The package includes three small ABI-2 bridges, C sources and maintainer build
scripts. `hook/build.dart` selects exactly one supported OS/architecture asset
through `CodeAsset` with `DynamicLoadingBundled`. It neither compiles nor fetches
anything and never executes inspected project code. The asset name and Native
FFI asset ID must agree (`package:archway/src/native/native_io.dart`). No runtime
source-checkout-relative locator or public asset override exists.

The SDK copies the selected asset with the installed executable. Preserve ABI
version/layout validation, paired allocation/free ownership, captured errors,
no-follow/exclusive/same-handle filesystem operations and raw alias semantics.
Missing/incompatible assets fail affected writes/alias observations closed; never
fall back to unsafe ordinary filesystem writes. Query-only operations need no
analysis runtime. `check` requires the externally prepared, pinned Dart SDK.

Track exactly the intended bridge bytes and provenance; an archive hash or source
match is not byte-reproducibility or new cross-platform runtime proof.

## Required evidence

The target cells remain Linux x64 Ubuntu 24.04/glibc, macOS arm64 macOS 15/APFS,
and Windows x64 Windows 11 24H2/NTFS. Other architectures, musl and network
filesystems are outside this declared envelope. CI runner results identify their
actual OS; Windows Server is not a Windows 11 certification.

Before claiming each platform, test actual SDK Git installation, real `init`
writes and prepared link-bearing Dart `check`, query and Mermaid export from an
unrelated directory with spaces/Unicode. Hide the original source checkout;
remove Node and C compilers from PATH. Verify update to a second revision,
reinstall and uninstall. Test missing and wrong-ABI assets using only isolated
test package/bundle copies. Preserve filesystem race, partial-output and raw-link
fault coverage. Do not count skipped cases as passes.

Dart/Flutter contexts, no project-code execution, runtime absence/failure,
canonical paths and evidence revalidation retain their separate acceptance gates.
A local Git install demonstrates the package mechanism, not public hosted URL
availability. After branch publication, test the exact public/authorized Git
command before claiming remote install acceptance. No test authorizes a release,
registry publication or merge into main.

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
