# Archway

Archway checks TypeScript and Dart dependencies against an explicit architecture
policy. Declare which modules own which files, which modules they may use, and
which files are public. Query a planned change before writing code, check prepared
projects, or export the declared graph as Mermaid.

## A small policy

Save this as `architecture.yaml` in a TypeScript project with `tsconfig.json`:

```yaml
version: 1
projects:
  - {id: web, adapter: typescript, tsconfig: tsconfig.json}
scope: [src/]
exclude: []
nodes:
  - id: app
    responsibility: Application entry points
    owns: [src/app/]
    allows: [core]
    public: []
  - id: core
    responsibility: Shared domain logic
    owns: [src/core/]
    allows: []
    public: [src/core/api.ts]
```

`app` can use `src/core/api.ts`, but cannot import other core files. Permissions
are direct, not transitive. A module with `public: []` exposes no files to other modules.
Ownership queries work for future files too. For Dart projects, use
`adapter: dart` and `package_roots: [./]` instead of `tsconfig`.

## Get Archway

Archway 0.2.0 is an unsigned preview with thin npm/pub launchers, a pinned
first-use native download and offline warm use. Check the
[GitHub releases page](https://github.com/GreatPika/archway/releases) for available
artifacts, `SHA256SUMS` and registry installation instructions. Use a registry
package only when that release lists it as published. You can also run Archway
from source. See the [delivery contract](contracts/compatibility/delivery.md)
for package requirements.

### Run from source

Install Dart 3.13.3 and Node 24.21.0/npm 11.19.0, then run these commands from
an Archway checkout. The native bridge command below requires Linux x64/glibc
and a C compiler; see the [installation guide](docs/implementation/installation-layout.md)
for macOS and Windows.

```sh
dart --suppress-analytics pub get
sh tool/build_native.sh
bash tool/prepare_typescript.sh
dart --suppress-analytics run bin/archway.dart --help
```

Dependency and helper preparation can download packages. Archway checks
already-prepared projects without installing dependencies or running project
builds, scripts or plugins.

Use the source command from this checkout and pass `--root` to select your project:

```sh
dart --suppress-analytics run bin/archway.dart --root /path/to/project validate
```

The project must have an `architecture.yaml` policy. Use the example above or
[generate starter files](#set-up-each-project).

To assemble a native executable on Linux or macOS, run:

```sh
sh tool/assemble.sh build/install
```

Choose a destination that does not already exist. Run
`build/install/bin/linux-x64/archway` on Linux or
`build/install/bin/macos-arm64/archway` on macOS. Keep the assembled directory
together; compiling the Dart entry point alone does not include the required assets.

Native policy, query, init and export commands need no external Node or Dart
runtime. TypeScript checks require Node 24.21.0; Dart checks require Dart 3.13.3.
Prepared Flutter projects use their compatible embedded SDK; see the
[Dart guide](docs/implementation/dart-check.md).

### Prepared packages

Developers can [stage packages locally](docs/implementation/installation-layout.md#stage-packages).
The [package guide](tool/npm/README.md) describes the 0.2.0 thin-wrapper routes
and installation requirements.

Portable bundles and unsigned native installers target Linux x64, macOS arm64
and Windows x64. Use the [bundle guide](tool/release/QUICKSTART.txt) only with
matching artifacts and checksums. Do not substitute a similarly named npm or pub
registry package.

Installation routes were tested in CI on Ubuntu 24.04 x64, macOS 15 arm64 and
Windows Server 2025 x64. CI tests do not establish public download or registry
availability; consult the release notes for public-download verification and
published packages. Windows 11 and downloaded-file GUI installation have not
been verified. Installers are unsigned, and the macOS installer is not notarized.

## Set up each project

The installation is shared; `architecture.yaml` and `ARCHITECTURE.md` belong
in each project. Run from that project's directory, or select it with `--root`.
From source, run from the Archway checkout and replace `archway` below with
`dart --suppress-analytics run bin/archway.dart`.

```sh
archway --root /path/to/project init --template mixed --dry-run
archway --root /path/to/project init --template mixed
```

Preview first, then create the starter policy and agent guide. Init refuses to
overwrite either file, including ASCII-case variants on every OS. It leaves a
legacy ARCHITECTURE_AGENT.md untouched without migration. Edit the policy to match the project's modules and use the
agent guide when working on that project. Without `--root`, the current directory
selects the project; the installer location never selects it.

## Commands

Below, `archway` means your installed command. From source, substitute
`dart --suppress-analytics run bin/archway.dart` from the checkout.

```sh
archway --root /path/to/project validate
archway --root /path/to/project owner src/app/new.ts
archway --root /path/to/project node app
archway --root /path/to/project allows app core
archway --root /path/to/project allows --paths src/app/new.ts src/core/api.ts
archway --root /path/to/project check
archway --root /path/to/project export --format mermaid
```

`node` without an ID lists the catalogue; `--offset` and `--limit` paginate it.
Export uses the declared graph, not inferred dependencies. Add `--out graph.mmd`
to write a file, and `--overwrite` only when replacing an existing output is
intended. Use `COMMAND --help` for options.

Operational results are JSON plus a newline; help/version are text. Mermaid
export writes Mermaid to stdout or a file, with JSON diagnostics on stderr.
`check` exits **0** when analysis completes without violations, **1** when it
completes with violations, and **2** when the policy is invalid or analysis is
incomplete. Missing prerequisites, unsupported cases and detected input changes
can prevent complete analysis. Filesystem rechecks do not provide an atomic snapshot.

## Known limitations

- With `npm exec`, signalling only the outer npm process may leave the CLI running.
  See [platform-specific process behavior](tool/ci/README.md#installed-npm-routes-and-termination-limits).
- Windows testing used Windows Server 2025 x64; Windows 11 has not been verified.
- The pub route uses `dart pub global activate --no-executables archway VERSION`
  then `dart pub global run archway:archway <args>`, without an alias or setup step.
  Offline use needs the prepared snapshot under the same SDK and verified native
  cache. After an SDK change, run `dart pub global run archway:archway --version`
  once before capturing JSON: SDK snapshot preparation can print dependency
  progress on the first invocation.

See the [installation guide](docs/implementation/installation-layout.md) for
platform requirements and installation limitations.

## Development

Start with [AGENTS.md](AGENTS.md) for specifications, implementation guides,
workflow, issue conventions and checks.

## License

Archway is available under the [MIT License](LICENSE). Third-party dependencies
retain their own licenses and notices alongside the bundled assets.
