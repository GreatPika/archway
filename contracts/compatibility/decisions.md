# Archway v1: pinned compatibility matrix and paths

Normative v1 matrix.

## 1. One version per component

- Dart SDK for analysis and CLI compilation: **3.13.3 stable**. Embedded `analyzer`: **14.5.0**, exact dependency and lockfile, no `^` in the release manifest.
- Compatibility is limited to these exact versions. Any other runtime version makes only the affected project incomplete. Add a patch version by changing the release manifest and rerunning the matrix; no automatic latest/update. Check security patches before release; do not publish a known-vulnerable pin merely to match the number.
- Experimental Dart language flags, custom SDKs, Bazel/GN and custom resolver plugins are unsupported in v1. Ordinary Dart packages and multiple Dart package roots are supported. TypeScript project declarations are rejected. Flutter projects are within the target envelope only with a stable SDK containing Dart **3.13.3**, readable SDK libraries/summary, package_config formatVersion=2 after the user has already run pub get, and resolvable Flutter package mappings. Record Flutter version/revision and SDK manifest hash in evidence; do not run Flutter CLI. Incomplete cache/missing generated source yields incomplete. This is a compatibility predicate, not a claim that a Flutter release has been tested; a required Flutter fixture for every target platform checks flutter package import, dart:ui, parts, generated imports, and missing SDK cache. The [official archive](https://docs.flutter.dev/install/archive) publishes Flutter/Dart mappings.
- Dart languageVersion: stable null-safe versions from 2.12 through 3.13 inclusive; per-file override must not exceed the package language version. Newer, legacy, and experimental variants yield incomplete rather than a retroactive version change. package_config formatVersion=2; configuration is already prepared by the user. No pub get/install, generation, or analyzer plugin execution during check.

Sources establish upstream properties, not Archway integration: [Dart 3.13.3](https://raw.githubusercontent.com/dart-lang/sdk/3.13.3/CHANGELOG.md) and [analyzer 14.5.0](https://pub.dev/packages/analyzer/versions/14.5.0).

## 2. Corpus and configurations

Corpus: case-sensitive `.dart`, including generated files, independently of
analyzer exclusions and gitignore. Directory scopes ignore non-Dart files.
Explicit non-Dart file scopes yield UNSUPPORTED_SCOPE_FILE warnings, not a promise
that those files were analyzed. Multiple declared Dart projects and prepared
package roots remain supported; overlapping contexts remain ambiguous.

## 3. Delivery: finite target list

The standard Dart package bundles assets for linux-x64 Ubuntu 24.04/glibc,
macos-arm64 macOS 15/APFS and windows-x64 Windows 11 24H2/NTFS. See
[delivery.md](delivery.md) for the single Git-install route and actual acceptance.
ARM Linux, Intel macOS, Windows ARM, musl and network filesystems are outside the
current target envelope. No Node, C compiler or Flutter dependency is imposed on
ordinary installation. Inspection uses a prepared external Dart SDK.

An asset's presence is not execution evidence. Require actual installed-command
and filesystem/runtime checks on each target before certification; preserve all
unrun gaps. No registry publication is implied.

## 4. Lexical paths: identical on every OS

1. `--root` is separate: an existing directory accepting native absolute/relative form. Canonicalize it once to the physical root. A symlink for root itself is allowed as an explicitly chosen root; this does not authorize child symlinks.
2. YAML `scope/exclude/owns` paths, relative configurations, and positional owner/allows paths are always repository-relative. `/` and `\\` are separators on every OS; the result uses only `/`. A POSIX filename containing a literal backslash is unrepresentable and yields incomplete when discovered.
3. Before normalization, reject absolute/UNC/device/drive-relative (`C:foo`) forms, URL schemes, NUL/control characters U+0000–001F/U+007F, `:*?"<>|[]{}`, Windows device segments CON/PRN/AUX/NUL/COM1–9/LPT1–9 (also with extensions, case-insensitively), and components ending in a space or dot except special `.` and `..`. Brackets `[]` and `{}` are also forbidden in all v1 policy and positional paths; discovering such a name in the corpus yields incomplete as an unrepresentable portable path. This is one portable subset; `%2e%2e` is not URL-decoded.
4. Normalize Unicode to NFC; preserve case. Empty paths are forbidden. Remove empty interior segments and `.`; `..` pops the preceding segment. An attempt to pop an empty stack is immediately forbidden even if later segments would return under root. `a/../b` => `b`; `../root/b` is invalid. Root as a directory prefix is `./`; `.` and `a/..` also normalize to `./`.
5. An original trailing separator preserves directory-prefix meaning. Otherwise the path is an exact file, except for normalized root. `src` and `src/` differ. Match prefixes at segment boundaries; `src/` does not include `src2/x.ts`. `A` and `a` differ even in a Windows policy-only query. No stat/realpath for future paths.
6. Normalize the whole policy first, then check owns overlaps. Merge duplicate/nested paths of one owner; overlaps between different owners are forbidden regardless of file existence. `exclude` takes precedence over scope/owner. YAML-path error => invalid policy/exit2; invalid positional CLI-path => usage/exit64.

These are Archway semantics, not a claim that every host filesystem is case-sensitive. [Windows naming](https://learn.microsoft.com/en-us/windows/win32/fileio/naming-a-file) explains why OS path APIs alone cannot define policy identity.

## 5. Physical verification: check

- Corpus traversal uses lstat on each segment; included file symlinks, directory symlinks, and junction/reparse aliases are not traversed and yield incomplete with the original lexical path. The corpus behind them is not considered successfully empty. An explicitly excluded subtree is not traversed; an import into it is still checked as a local target and a violation if confirmed.
- The physical canonical target after resolution is required in addition to the lexical path. Check containment by canonical-root segments, not a string prefix. Identical actual content does not change the policy owner.
- Every segment of an ordinary included file must have exactly the spelling seen in directory entries after NFC. Case mismatch on a case-insensitive filesystem yields incomplete; ownership of future `src/A.ts` does not arbitrarily become ownership of `src/a.ts`. Two names collapsing after NFC or resolver canonical pathname yield alias ambiguity unless there is one compatible identity/owner. Two actual files differing in case on Linux remain distinct.
- Physical identity in v1 means the canonical pathname observed through resolver/realpath, not inode or byte equality. Two hardlink directory entries remain distinct paths and owners; check imports to each path by the actual resolved name. Detectable canonical/resolver aliases with ownership conflicts yield incomplete. Discovering all hardlinks or treating inode equality as policy identity is outside this contract. An inaccessible/unknown reparse type still prevents confirming safe traversal.
- The only symlink exception is a resolver package-manager alias that is not an included corpus source. A prepared package mapping alias may resolve to an ordinary physical file; retain original specifier, logical resolved path, symlink hops, and canonical target. Classify provenance before checking location: compiler/package manifest + lock/config evidence must distinguish an installed third-party package from a repository/project/workspace/path dependency. Presence under canonical root, a cache-directory name or package: URI spelling alone does not prove the category. Broad owns ["./"] and analyzer context membership also do not reclassify a proven installed third-party package as local. An alias does not add a second owner. A source behind a symlink in scope remains forbidden even if the alias looks like a package path.
- A confirmed installed third-party package is external whether its canonical target is inside root (for example a prepared package cache) or outside. A confirmed repository/project/workspace/path dependency remains local regardless of location: inside root, owner follows the canonical repository-relative target; outside, known local outside_scope => violation. Ambiguous or contradictory provenance yields incomplete, not external by default. An SDK source is builtin only from a verified SDK root. Changes in owner/status between physical aliases => incomplete; retain already reliable violations. This target classification does not reduce the authoritative source corpus of scope minus exclude: explicitly selected vendor/source files do not automatically disappear.
- Cyclic/unreadable symlinks, escapes, file/config/alias-chain changes during reading, and unconfirmable canonical identity yield incomplete. The list and hashes of read inputs, including configurations, package manifests/lockfiles, and alias evidence, form part of input identity. This detects changes within the check window; it does not promise a filesystem snapshot or protection against a malicious concurrent writer.

## 6. Runtime preflight boundaries

CLI uses direct spawn with argv, without a shell. Look up an external runtime through PATH once and pin its absolute executable; reject cwd/empty PATH entries and repo-local executable substitutions. An explicitly invoked Archway installation may reside inside the repository under delivery.md; this does not authorize repo-local external runtimes. Do not execute repository wrappers, npm scripts, hooks, or project plugins. Clear NODE_OPTIONS, NODE_PATH, and loader/preload influence before version checking and runtime execution. Analyze user code as data.

Version preflight: 5 seconds wall time, up to 64 KiB combined output. Verify
Dart SDK readable version metadata and SDK libraries; do not replace embedded
analyzer with a project's analyzer. Missing/different runtime makes affected
analysis incomplete; retain independent evidence. No version fallback, downloads
or automatic installation. Timeout/cancellation permits two seconds for cleanup;
unconfirmed termination is explicit and prevents further runtime launches.

## Implementation acceptance

Release acceptance requires real fixtures on all three target OS/architecture combinations and confirmation that incomplete analysis cannot report success and that inspection performs neither network access nor project-code execution. `adversarial-cases.json` defines expected-behavior scenarios; `lexical_reference.dart` defines a finite lexical model, not the host filesystem.

## Compiler host feasibility gate

Before expanding the CLI, verify on small real projects with pinned versions: positive reads, negative probes and directory inventories, every Dart conditional URI branch, and analyzer context assignment. Verify that evidence reaches input_identity and the final independent reconciliation. If reliable tracing is impossible, stop implementation expansion and clarify the supported boundary; a fixture model does not replace this gate.

The exact bounded installed-provenance classifier is in package-provenance.md. Supported joins: pub package_config v2 with selected lock/workspace/SDK metadata. Other formats do not default to external.
