# Package target provenance

This finite v1 classifier profile supplements [compatibility decisions](decisions.md). Keep the existing local/external/builtin/unresolved result variants; failure to prove a required join produces an unresolved classification and unknown/incomplete diagnostic for the affected reference, not a new field or category.

Start with the actual compiler final target, observed and canonical package root, selected context's effective metadata and target manifest. Join the exact installed instance, not its name alone. This checks consistency of prepared local metadata, not authenticity of installed bytes. Record classification metadata, alias reads and negative probes in existing input evidence and direct fact input references. Do not run package-manager commands, fetch, evaluate hooks or infer origin from containment, node_modules, Program membership or compiler external flags alone.

## Supported joins

| Manager and format | Required instance join | External evidence | Local evidence |
| --- | --- | --- | --- |
| npm lockfileVersion 2 or 3 | Effective npm-shrinkwrap.json takes precedence over package-lock.json; join its packages row for the observed install location, effective dependency source, target package.json name/version and canonical package root. No hidden node_modules/.package-lock.json fallback. | Non-link registry or remote-tarball resolution, or remote Git URL pinned to a commit, with agreeing installed instance. | link:true resolved directory or explicit local file-directory source with agreeing actual mapping and manifest. A copied local directory can be non-link. Local tarball/local Git source is local only when prepared source and instance identity are proven; otherwise unknown. |
| pnpm lockfileVersion 9.0 | Join importer dependency ref or parent snapshot dependency ref to the exact snapshot/package resolution and actual installed instance/manifest; retain peer suffix identity. Use prepared installed-layout metadata for a moved virtual store, not guessed directory spelling. | Registry integrity, remote tarball, or remote Git repository and commit resolution, with agreeing instance. | Effective link:/file: refs proving workspace/path origin, including injected or copied packages. workspace: alone is insufficient if the actual mapping disagrees. |
| pub package_config formatVersion 2 and selected pubspec.lock | Map actual target via selected rootUri/packageUri; join lock source/version/description with target pubspec and installed instance. | hosted source with agreeing instance; git requires remote URL, resolved-ref and package subpath plus config/instance agreement. | Effective workspace manifests and shared package_config establish workspace members before hosted-looking constraints; otherwise source:path description relative to lock directory plus agreeing config/pubspec. Local-path/file Git is local only when proven, otherwise unknown. |

A confirmed installed external package stays external inside or outside the repository. A workspace/path/repository dependency stays local inside or outside: outside-root local is a known outside_scope violation. Non-link status does not prove external. HTTP(S) artifacts and remote Git origins do not override contradictory effective workspace/local evidence. No Git invocation or fetch is required to classify.

## SDK and Flutter

A verified compiler SDK library target is builtin. Pub source:sdk names an SDK; it does not alone prove a trusted target. source:sdk description:flutter together with the selected verified Flutter installation, selected package_config mapping and matching SDK package path/pubspec (SDK/packages/<name> or SDK/bin/cache/pkg/<name>) establishes builtin for Flutter-distributed SDK packages, including flutter and flutter_test. The existing stable Flutter/embedded Dart 3.13.3 compatibility predicate still applies. dart:ui uses the verified selected Flutter SDK libraries/summaries. Flutter dependencies obtained from hosted/git sources retain their own external provenance; local overrides remain local. An import named package:flutter does not alone prove builtin. A proven SDK mapping can establish builtin without a lock when independent SDK evidence suffices. Missing or contradictory source metadata affects that reference, not all normal Flutter SDK imports.

## Incomplete evidence

A missing required join, unrecognized pnpm layout, conflicting version/root/alias/workspace override, or multiple applicable package managers leaves the affected reference unknown/incomplete. Preserve independent known local and SDK facts; never choose external to resolve a conflict. Unsupported lock formats affect classifications requiring that metadata, not unrelated relative imports. Missing required Dart package_config remains the existing project configuration/discovery failure. Recheck every classifier input for mutation under the normal input identity contract.

## Acceptance cases

For each of npm, pnpm and pub, run real prepared-package fixtures for registry inside root, workspace inside root, local path outside root, supported remote Git/tarball, missing required lock and conflicting alias/version. Add npm shrinkwrap precedence and non-link local install; pnpm peer snapshots and injected local package; pub missing config and workspace membership despite hosted-looking constraints. Flutter cases cover SDK package imports and dart:ui, plus misleading SDK metadata pointing outside the selected SDK. Change each classifier input during observation and verify incomplete while retaining independent facts. These requirements need measured results from real compiler runs; the scenarios alone are not evidence of execution.

## Primary sources

- [npm lock format and precedence](https://docs.npmjs.com/cli/v11/configuring-npm/package-lock-json/)
- [pnpm lock 9.0](https://raw.githubusercontent.com/pnpm/spec/master/lockfile/9.0.md), [installed layout](https://pnpm.io/symlinked-node-modules-structure), [workspaces](https://pnpm.io/workspaces), [local injection](https://pnpm.io/package_json)
- [Flutter SDK package lookup and version metadata](https://raw.githubusercontent.com/dart-lang/pub/master/lib/src/sdk/flutter.dart)
- [pnpm resolution variants](https://raw.githubusercontent.com/pnpm/pnpm/main/resolving/resolver-base/src/index.ts)
- [pub lock source/version/description](https://raw.githubusercontent.com/dart-lang/pub/master/lib/src/lock_file.dart), [workspace precedence and shared configuration](https://dart.dev/tools/pub/workspaces), [Git revision and subpath](https://raw.githubusercontent.com/dart-lang/pub/master/lib/src/source/git.dart), [SDK identity and package path](https://raw.githubusercontent.com/dart-lang/pub/master/lib/src/source/sdk.dart)
