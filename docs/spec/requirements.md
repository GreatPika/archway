# Archway v1 requirements

Exact behavior is defined by [the contracts](../../contracts/README.md).

## Purpose and boundary

A local, offline CLI lets people and coding agents declare flat modules, responsibilities, future owned paths, exact public files and direct allowed dependencies before code exists. The same policy answers targeted questions and checks observed Dart/TypeScript module references. A green check establishes this bounded architecture check, not application correctness, complete implementation, symbol access, runtime reachability or architectural quality.

## Policy

- One UTF-8 YAML 1.2 document. Required root keys are `version`, `projects`, `scope`, `exclude`, `nodes`; v1 rejects unknown keys and unsupported scalar/parser constructs. The default filename stays `architecture.yaml`.
- A project explicitly declares a TypeScript tsconfig or Dart package roots. A flat node declares `id`, `responsibility`, `owns`, required `public`, `allows` and optional `contracts`. No nesting, inheritance or hierarchy exists.
- Paths are portable root-relative lexical exact files or directory prefixes ending `/`; no glob. Normalize separators, NFC and dot segments while preserving case and rejecting escape. Different owners may not overlap, including planned paths. Same-owner redundancy normalizes away. `exclude` takes priority.
- Each `public` entry is an exact owned file within scope and outside exclude. Future files and extensionless files are valid without stat. Directories/globs are invalid. `public: []` seals cross-owner file access; omission is invalid.
- Same-owner dependencies are allowed. Cross-owner file dependencies require both a direct `allows` edge and the exact resolved target in the target owner's `public`. Permissions are directed and nontransitive. Cycles warn; a DAG is not required. `contracts` references explain intent; missing local documents warn and network URLs are never fetched automatically.
- Exact parser restrictions, path semantics, public diagnostic precedence and policy pointers are defined by [decision.md](../../contracts/json/decision.md) and [compatibility](../../contracts/compatibility/decisions.md).

## CLI and results

`archway` exposes `validate`, `owner`, `node`, `allows`, `check`, `init`, and Mermaid `export`. `--root` selects one existing root without parent search. Read commands accept `--policy`; init rejects it before writes. All other path arguments are root-relative.

- `validate`: policy shape and semantics, without requiring planned source files.
- `owner PATH`: owned, excluded, outside_scope or unowned for an existing or future path, without stat.
- `node`: complete catalogue sorted by id. Only explicit limit/offset paginates; total, omitted and policy hash remain visible. `node ID` or `node --path PATH` returns complete direct context, including responsibility, owns, public, contracts, outgoing allows and incoming allowed_dependents, without recursive expansion or source code.
- `allows FROM_ID TO_ID`: module permission only, including a sealed target. `allows --paths FROM TO`: exact-file ownership plus direct permission/public predicate, without resolver or stat. Both are policy-only and distinguish allowed, denied and undetermined; path-mode directory operands are usage errors.
- `check`: freshly loads the policy, determines the authoritative source corpus, observes real compiler evidence, applies the same Plan predicate, rechecks inputs, and emits the complete report.
- `--help` and `--version`: standalone text modes. Except for Mermaid export, other operational result modes are one complete UTF-8 JSON document plus LF, with no streaming, hidden truncation or human-output mode. Logs never enter stdout.
- The envelope identifies `tool_versions.archway`, independent schema version, selected root/policy, exact raw policy-byte hash, status, exit code, diagnostics and typed payload. Nullable fields are present; arrays are never omitted. Recovery hints are literal text, never executed.
- Exit codes are 0 for successful/allowed/full-clean results, 1 for denied/unmatched or complete violations, 2 for invalid policy, tool error or incomplete analysis, and 64 for usage error. Incompleteness takes precedence while preserving independently known violations. Warnings alone do not change the exit code.

Exact grammar, envelopes and command-specific status/exit combinations are in [the public machine contract](../../contracts/json/decision.md) and its schemas. The summary above does not replace command-specific distinctions.

## Complete bounded inspection

- Independently enumerate scope minus exclude, including generated source and declarations: `.dart`, `.ts`, `.tsx`, `.mts`, `.cts`, `.d.ts`, `.d.mts`, `.d.cts`. Compiler exclude and gitignore do not shrink the corpus. Recognized unsupported source kinds remain in coverage and make analysis incomplete.
- Every file needs exactly one confirmed project/context candidate after all relevant discovery. Zero, multiple or unfinished discovery is incomplete, with explicit candidates/descriptors. Ownership does not assign compiler context. An empty plan does not hide a nonempty or unreadable corpus.
- Resolution facts distinguish proven local, external, builtin and unresolved targets. Package provenance, not location, specifier spelling, broad ownership or Program membership, determines classification. Installed third-party code can be external inside the root; repository/workspace/path code remains local outside it. Uncertain provenance is incomplete.
- Check local excluded/outside/unowned target violations first, even with an unowned source. Then apply same-owner, direct allows, exact public in that order. One edge never gets both graph-denial and public-denial diagnostics. Facades do not transitively expose private files; every re-export edge is checked separately. Actual redirected `.d.ts` targets are not remapped to guessed source files.
- Dart uses analyzer contexts, prepared package configuration, imports, exports, supported conditional URI branches, parts and proven part-of links. Dart library membership does not require common ownership. Unsupported/failed interpretation remains incomplete.
- TypeScript uses the bundled Compiler API, actual Program membership, explicit tsconfigs/extends and prepared project-reference declaration outputs. It does not add scope files to rootNames or run a build. Supported literal module references include type-only, import types, require and dynamic import. Computed specifiers and unrepresented explicit triple-slash/augmentation constructs give positioned unknowns; ambient/global coupling is outside the import-graph guarantee.
- Included source symlinks/junctions are not traversed. Resolver package aliases retain canonical targets and provenance. Physical identity, case/NFC ambiguity and containment are verified independently of policy-only lexical rules.
- Reports retain policy validity, analysis completeness, violations, unknowns, warnings, tool errors, coverage, reliable facts and input identity separately. Positive reads, absent probes, directory inventories and aliases must reach final independent revalidation. `atomic_snapshot` is always false. Cross-project observation conflict invalidates affected facts/discovery and remains incomplete even if the final bytes match one observation.
- Missing/failing runtime affects its project; independent evidence from other projects survives. No project code, loader, plugin, lifecycle script, build, SDK download, dependency install or network access is executed by Archway.

## Safe initialization and export

Init requires a dart/typescript/mixed template and creates exactly `architecture.yaml` and `ARCHITECTURE_AGENT.md`. The policy has valid empty arrays; templates change comments only. Dry-run reports complete contents without writes but still reports conflicts. Both targets are checked; exclusive creation and identity-safe rollback remove only this invocation's files. Partial outcomes report residual files. Crash-atomic two-file writes are not promised. Existing policy/guide recovery requires an explicit user decision; no force, merge or overwrite behavior exists.

The guide covers selecting/recovering the root/policy, agreeing a plan before code, querying exact context, checking each proposed file dependency, running full check and application tests, and separately approving policy changes. It never weakens policy automatically. The quickstart offers a manual AGENTS.md pointer; init does not change AGENTS.md, CI or editor settings.

Mermaid export renders every declared flat module and only direct declared permissions, with declared-policy labeling and the policy hash. It does not render observed use, nested structure or symbol edges. Escape all user text and use deterministic safe identifiers. Successful stdout export is Mermaid plus LF; file export leaves stdout empty and requires explicit overwrite for an existing target. Diagnostics, if any, are exactly one JSON object plus LF on stderr. Error stdout is empty, subject to process/stream-failure limits. No renderer or browser is required.

## Delivery

Exact baseline: Dart SDK 3.13.3, embedded analyzer 14.5.0, Node 24.21.0 LTS, bundled TypeScript 5.9.3. They are contract pins, not evidence of availability or integration. Flutter is conditional on a compatible stable SDK, prepared mappings/cache and real acceptance; no Flutter release is claimed certified.

Deliver the same Dart core through native AOT archives, one npm package containing all three native payloads, and a pub source CLI package with prebuilt native bridges. The target cells remain Linux x64 Ubuntu 24.04/glibc, macOS arm64 macOS 15/APFS, and Windows x64 Windows 11 24H2/NTFS. All carry the required helper/compiler assets, schemas, manifests/hashes, licenses and guide. npm launch requires Node but no Dart SDK; pub launch requires Dart. Policy/query/init/export need no additional analysis runtime, and the native payload itself needs neither external runtime. TypeScript check requires external Node; Dart check requires the external SDK. Exact layout, trust and installation gates are in [package delivery](../../contracts/compatibility/delivery.md). Release waits for all three real-platform cells and package-route acceptance or an explicitly approved scope revision.
