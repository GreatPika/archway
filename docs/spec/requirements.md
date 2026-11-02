# Archway v1 requirements

Exact behavior is defined by [the contracts](../../contracts/README.md).

## Purpose and boundary

A local, offline CLI lets people and coding agents declare flat modules, responsibilities, future owned paths, exact public files and direct allowed dependencies before code exists. The same policy answers targeted questions and checks observed Dart module references. A green check establishes this bounded architecture check, not application correctness, complete implementation, symbol access, runtime reachability or architectural quality.

## Policy

- One UTF-8 YAML 1.2 document. Required root keys are `version`, `projects`, `scope`, `exclude`, `nodes`; v1 rejects unknown keys and unsupported scalar/parser constructs. The default filename stays `architecture.yaml`.
- A project declares adapter: dart and nonempty package_roots; multiple Dart projects/roots remain supported. Other adapter declarations are rejected. A flat node declares `id`, `responsibility`, `owns`, required `public`, `allows` and optional `contracts`. No nesting, inheritance or hierarchy exists.
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

- Independently enumerate scope minus exclude, including generated `.dart` source. Compiler exclude and gitignore do not shrink the corpus. Directory scopes ignore non-Dart tooling/data. Explicit non-Dart file scopes get UNSUPPORTED_SCOPE_FILE warnings.
- Every file needs exactly one confirmed project/context candidate after all relevant discovery. Zero, multiple or unfinished discovery is incomplete, with explicit candidates/descriptors. Ownership does not assign compiler context. An empty plan does not hide a nonempty or unreadable corpus.
- Resolution facts distinguish proven local, external, builtin and unresolved targets. Package provenance, not location, specifier spelling, broad ownership or analyzer context membership, determines classification. Installed third-party code can be external inside the root; repository/workspace/path code remains local outside it. Uncertain provenance is incomplete.
- Check local excluded/outside/unowned target violations first, even with an unowned source. Then apply same-owner, direct allows, exact public in that order. One edge never gets both graph-denial and public-denial diagnostics. Facades do not transitively expose private files; every re-export edge is checked separately.
- Dart uses analyzer contexts, prepared package configuration, imports, exports, supported conditional URI branches, parts and proven part-of links. Dart library membership does not require common ownership. Unsupported/failed interpretation remains incomplete.
- Included source symlinks/junctions are not traversed. Resolver package aliases retain canonical targets and provenance. Physical identity, case/NFC ambiguity and containment are verified independently of policy-only lexical rules.
- Reports retain policy validity, analysis completeness, violations, unknowns, warnings, tool errors, coverage, reliable facts and input identity separately. Positive reads, absent probes, directory inventories and aliases must reach final independent revalidation. `atomic_snapshot` is always false. Cross-project observation conflict invalidates affected facts/discovery and remains incomplete even if the final bytes match one observation.
- Missing/failing runtime affects its project; independent evidence from other projects survives. No project code, loader, plugin, lifecycle script, build, SDK download, dependency install or network access is executed by Archway.

## Safe initialization and export

Init defaults to Dart and accepts optional --template dart; other templates are usage errors. It creates exactly `architecture.yaml` and `ARCHITECTURE.md`. The policy has valid empty arrays; the Dart template changes comments only. Dry-run reports complete contents without writes but still reports conflicts. Both targets are checked; exclusive creation and identity-safe rollback remove only this invocation's files. Partial outcomes report residual files. Crash-atomic two-file writes are not promised. Existing policy/guide recovery requires an explicit user decision; no force, merge or overwrite behavior exists. Init conservatively refuses ASCII-case variants of either fixed output name on every OS before any write, including files, directories and dangling links. This narrow init rule does not change general policy/corpus case identity. Dry-run remains bridge-free. A legacy ARCHITECTURE_AGENT.md is left untouched; it is not migrated or treated as an output alias. The schema_version 1 init filename enum contains architecture.yaml and ARCHITECTURE.md.

The guide covers selecting/recovering the root/policy, agreeing a plan before code, querying exact context, checking each proposed file dependency, running full check and application tests, and separately approving policy changes. It never weakens policy automatically. The quickstart offers a manual AGENTS.md pointer; init does not change AGENTS.md, CI or editor settings.

Mermaid export renders every declared flat module and only direct declared permissions, with declared-policy labeling and the policy hash. It does not render observed use, nested structure or symbol edges. Escape all user text and use deterministic safe identifiers. Successful stdout export is Mermaid plus LF; file export leaves stdout empty and requires explicit overwrite for an existing target. Diagnostics, if any, are exactly one JSON object plus LF on stderr. Error stdout is empty, subject to process/stream-failure limits. No renderer or browser is required.

## Delivery

The root package is installed with the standard Dart SDK Git descriptor command
in [package delivery](../../contracts/compatibility/delivery.md). SDK analysis pin
is 3.13.3 and embedded analyzer is 14.5.0. Prepared Flutter compatibility is retained
without a Flutter dependency or new certification claim.

Bundled ABI-2 native filesystem assets target Linux x64/glibc, macOS arm64 and
Windows x64. A selection-only SDK build hook replaces custom archives, npm/pub
wrappers and runtime downloading; no end-user C compiler or Node is required.
`publish_to: none` remains; branch publication is not registry publication.
Target-cell/runtime acceptance is recorded separately, never inferred from the
presence of bridge bytes. Policy/schema version 1 and nullable legacy tool-version
keys remain compatible for Dart clients; TS project declarations are unsupported.
