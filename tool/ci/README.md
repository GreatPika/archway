# Dart package checks

The [package workflow](../../.github/workflows/dart-package.yml) checks the ordinary
Dart package on Ubuntu 24.04 x64, macOS 15 arm64, and Windows Server 2025 x64.
A runner result establishes only its actual host: Windows Server is not Windows
11 certification. Unrun platform jobs are not successful acceptance.

The workflow uses the reviewed official Dart 3.13.3 archive and SHA-256 pins,
lock-enforced package preparation, packaged-asset inventory verification,
`dart analyze`, the full `dart test` suite, and `dart contracts/run_tests.dart`.
Windows developer process fixtures are built before tests. A separate maintainer
bridge build writes under `build/`, never over the three packaged bridge files.
Users do not need a compiler: the package hook selects an existing bundled asset.
The GitHub release supplies ordinary source archives. No npm, custom installer,
standalone executable archive, download cache or registry publication is part of
the delivery route. CI has read-only repository permissions. Pushes to main and
version tags run the package matrix; a tag must resolve to the tested main commit.
The initial release is a qualified prerelease, not a claim that the full stable
platform matrix has passed.

## Optional genuine Dart and Flutter fixtures

Fixture preparation is separate from inspection. `prepare_native_acceptance.dart`
retains the pinned official Flutter 3.47.4 / Dart 3.13.3 preparation and genuine
hosted, path, workspace and pinned Git fixtures. It downloads no Node runtime.
It requires a clean tracked source checkout, installed Git and platform extraction
tools, and a fresh output directory:

```sh
dart run tool/ci/prepare_native_acceptance.dart --target linux-x64 --output /absolute/fresh-fixtures
```

Use `macos-arm64` or `windows-x64` on those actual hosts. Preparation records
commands, hashes and readiness evidence. Select its `git-fixture` project through
`ARCHWAY_PUB_GIT_FIXTURE` and its `flutter-fixture` project through
`ARCHWAY_FLUTTER_FIXTURE`; choose the prepared embedded Dart SDK on PATH for Flutter
checks. These fixtures are optional for local development, and corresponding
skips must be reported. They are not a product Flutter dependency.

The retained process support tests exercise capture, deadlines, raw streams,
cleanup, Windows Job Objects and OS-specific filesystem controls. Fixture cleanup
is not a universal product process-tree guarantee. The public CLI's application
architecture check remains separate from application unit tests.

## Installed lifecycle

`dart run tool/installation_lifecycle.dart` uses an isolated home/cache and a
private temporary Git fixture. It installs a test predecessor, updates to the
exact committed release tree, reinstalls that revision, uninstalls, and installs
again. Each stage checks the real installed version and command behavior while
the source fixture and Git cache checkouts are unavailable. Hosted dependency
bytes may be copied from the driver cache; this proves SDK lifecycle behavior,
not a fresh remote dependency download. The ordinary installed-package step
runs the complete fault suites separately. No fixture commits are published.
