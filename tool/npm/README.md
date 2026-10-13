# Archway packages

Archway checks prepared TypeScript and Dart projects against architecture.yaml.
These instructions use a verified Archway 0.1.0 tarball or a locally prepared
package. Check the [GitHub releases page](https://github.com/GreatPika/archway/releases)
for unsigned preview artifacts. npm and pub registry packages are not published.
See the
[staging guide](https://github.com/GreatPika/archway/blob/main/docs/implementation/installation-layout.md#stage-packages).
Install the explicit tarball path; do not substitute a similarly named registry package.
Archway is licensed under the MIT License included in `LICENSE`. Dependency
licenses and notices remain with their bundled assets.

## npm users

The assembled npm tarball contains native executables, bridges and shared
compiler assets. Node is required to launch it; TypeScript checks require Node
24.21.0 and use bundled TypeScript 5.9.3. Dart checks additionally require external
Dart 3.13.3. npm users need no C compiler or Dart SDK for TypeScript-only checks.

Install your verified tarball as a local development dependency from your project:

```sh
npm install --save-dev --ignore-scripts "/absolute/path/to/archway-architecture-cli-0.1.0.tgz"
npm exec --offline -- archway --help
npm exec --offline -- archway --root /path/to/project validate
```

Replace the tarball path with the actual downloaded file, quoting paths with
spaces. Add `--offline` to installation only when any other dependencies npm needs
are already available in your cache.
Archway has no lifecycle scripts; its launcher does not download or build payloads.
Prepared packages may contain only a subset of supported targets. Check
`manifest.json` for the targets included in your package.

For a command shared across projects, install the same tarball globally:

```sh
npm install --global --ignore-scripts "/absolute/path/to/archway-architecture-cli-0.1.0.tgz"
archway --help
```

Use a writable npm global prefix whose command directory is on PATH, then open a
fresh terminal. To update, install the newer downloaded tarball the same way;
remove with `npm uninstall --global archway-architecture-cli`. For a local install,
run `npm uninstall --save-dev archway-architecture-cli` in its project.

For an explicit cache/exec route, run outside a project with a local Archway
installation so npm cannot select that local command:

```sh
npm exec --yes --ignore-scripts --package="/absolute/path/to/archway-architecture-cli-0.1.0.tgz" -- archway --help
```

Use `--offline` for subsequent runs once the required bytes are cached. These
commands select an explicit tarball file, not a registry name. See the
[CI guide](https://github.com/GreatPika/archway/blob/main/tool/ci/README.md) for platform-specific
process and cancellation limitations.

## Dart users

There is no published pub package. The current developer route uses a prepared,
verified source stage, not an ordinary checkout or a hosted package. Follow the
[staging guide](https://github.com/GreatPika/archway/blob/main/docs/implementation/installation-layout.md#stage-packages)
and [local Git snapshot fixture](https://github.com/GreatPika/archway/blob/main/tool/ci/README.md)
to assemble and verify it. It contains prebuilt bridges matching the target and
shared compiler assets.

For that verified stage committed to a local Git repository, activate its exact
commit with Dart 3.13.3, then run setup using the same SDK and PUB_CACHE:

```sh
dart pub global activate --source git --git-ref FULL_STAGE_COMMIT file:///absolute/path/to/verified-stage-repository
dart pub global run archway:setup
archway --version
```

Replace the commit and file URI with the actual prepared stage values (Windows
file URIs use `file:///C:/...`). Activation may fetch dependency metadata. Put the
pub cache's `bin` directory on PATH and open a fresh terminal before using
`archway`. Pub needs Dart to launch; TypeScript checks also need Node 24.21.0.
Repeat activation and setup to update; use `dart pub global deactivate archway`
to remove the global activation.

Setup repairs only the known Dart 3.13.3 generated launcher: POSIX quoting or
Windows fallback exit propagation. Repeated setup and recognized path-activation
launchers are no-ops. Repeat setup after every activation/update, which can
regenerate the SDK launcher. See the
[setup explanation](https://github.com/GreatPika/archway/blob/main/docs/implementation/installation-layout.md)
for the launcher defects and refusal conditions.

## Usage and layout

From the npm project where you installed the tarball, preview starter files with
`npm exec --offline -- archway init --template mixed --dry-run`. For a globally
activated Dart package, use
`archway --root /path/to/project init --template mixed --dry-run`.
Choose a project without architecture.yaml or ARCHITECTURE_AGENT.md. Remove
`--dry-run` to create them, then edit architecture.yaml for your project.
For `validate`, `owner`, `node`, `allows`, `check` or `export --format mermaid`,
keep the same invocation prefix and replace the init arguments.
`--root` selects the inspected project.
Check never installs dependencies or runs project builds, scripts or plugins.

Native npm payloads are in `bin/<target>/archway` (`archway.exe` on Windows),
bridges in `native/<target>/`, and shared assets in `assets/`. Preserve the whole
package when relocating. manifest.json records versions and file hashes;
schemas/ contains result schemas. The launcher verifies the selected payload
hash against its manifest to detect corruption, not malicious paired replacement
or concurrent mutation. Prelaunch errors use stderr/exit 126; core output and
exit codes pass through unchanged. Signal behavior is OS-specific.

`check` exits 0 when analysis completes without violations, 1 when it completes
with violations, and 2 when the policy is invalid or analysis is incomplete.
Operational results are JSON; export emits Mermaid with separate JSON diagnostics. Use command-specific --help for options.
If Archway is installed inside the project being checked, configure `scope` and
`exclude` to select the files you want to inspect.
