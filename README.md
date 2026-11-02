# Archway

Archway checks **Dart** dependencies against an explicit architecture policy.
Declare module ownership, responsibilities, public files and direct allowed
permissions. Ask about a planned change before writing code; check prepared Dart
projects; export the declared graph as Mermaid.

## Install

Current source requires Dart SDK **3.13.5**; this update is unreleased.
The published **v0.1.0** still requires Dart SDK **3.13.3** and Git:

```sh
dart install 'archway@{git: {url: https://github.com/GreatPika/archway.git, ref: v0.1.0}}'
archway --help
```

If Dart reports that its installation bin directory is not on PATH, apply the
PATH instruction printed by Dart. The SDK manages installation and the command;
there is no Archway installer, npm wrapper or first-run download.

This is the **0.1.0 preview release**, distributed through Git, not pub.dev.
`publish_to: none` remains set. Repeat the command to reinstall this pinned
version; select a later release tag explicitly to update. Use
`dart uninstall archway` to remove it. The [release](https://github.com/GreatPika/archway/releases/tag/v0.1.0)
contains source archives, not a separate installer.

Package CI exercises Ubuntu 24.04 x64, macOS 15 arm64 and Windows Server 2025
x64. Windows 11 desktop and the complete prepared Flutter matrix are not yet
certified; the [required acceptance matrix](docs/spec/acceptance.md#required-release-matrix)
remains the gate for a fully validated stable release.

The package bundles tiny native filesystem bridges for Linux x64/glibc,
macOS arm64 and Windows x64. No Node, Flutter SDK or C compiler is required to
install Archway. The standard Dart build hook only selects the bundled asset.
Target platform requirements and acceptance limits are in the
[delivery contract](contracts/compatibility/delivery.md); bundled bytes alone do
not establish execution on every platform.

## First project

From your project directory:

```sh
archway init
```

This creates `architecture.yaml` and `ARCHITECTURE.md` without overwriting
anything. The initial policy is intentionally empty: agree ownership and allowed
dependencies before filling it in. For example:

```yaml
version: 1
projects:
  - id: app
    adapter: dart
    package_roots: [./]
scope: [lib/]
exclude: []
nodes:
  - id: app
    responsibility: Application entry points
    owns: [lib/app/]
    allows: [core]
    public: []
  - id: core
    responsibility: Shared domain logic
    owns: [lib/core/]
    allows: []
    public: [lib/core/api.dart]
```

`app` may import `lib/core/api.dart`, not core's private files. Permissions are
explicit, direct and nontransitive. Same-owner references are allowed.

```sh
archway validate
archway owner lib/app/future.dart
archway node core
archway allows --paths lib/app/main.dart lib/core/api.dart
archway check
archway export --format mermaid --out architecture.mmd
```

If init fails, it reports residual paths for manual inspection without
automatically deleting files. Review each path before removing or recovering it;
retry only after both startup names are free.

Use `--root /path/to/project` from another directory. There is no upward policy
search. Commands return complete JSON and meaningful exit codes (0 success,
1 negative, 2 invalid/incomplete/error, 64 usage); Mermaid export is text.

Before `check`, prepare the project's dependencies yourself with its normal
workflow. Archway never runs `pub get`, build scripts, project code or analyzer
plugins. Dart analysis currently pins SDK 3.13.5 and analyzer 14.5.0. Existing
prepared Flutter projects can use their matching embedded Dart SDK and package
mappings; Flutter is not an Archway dependency or a newly certified integration.

Directory scopes analyze `.dart` only; incidental JS/TS tooling is ignored.
Explicit non-Dart file scopes receive a warning. Ownership queries remain
language-neutral, including future paths. A clean check means this bounded
architecture check passed, **not** that the application has no bugs.

## Contributing and architecture

```sh
dart pub get
dart analyze
dart test
dart contracts/run_tests.dart
```

Optionally add a manual pointer in your project's `AGENTS.md`: “Follow ARCHITECTURE.md
and validate dependencies with Archway.” Init never edits AGENTS.md or CI.

The repository has four owners: Plan, Inspection, CLI and Bootstrap. See
[architecture](docs/spec/architecture.md), [contracts](contracts/README.md),
[acceptance](docs/spec/acceptance.md) and [porting](docs/porting.md). The Dart
implementation is the reference; future ports should preserve policy/result
semantics rather than inherit a speculative framework.
