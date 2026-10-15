# Archway v1 acceptance

Acceptance fixtures define expected behavior; they are not evidence of recorded Archway execution.

## Ordered gates

1. Pin the declared dependencies and verify their availability. Before production expansion, complete the **compiler-host feasibility gate** on small real projects: positive reads, negative probes and directory inventories; prepared TS redirects; every supported Dart conditional URI branch; analyzer contexts; propagation to input identity and independent final revalidation. If trustworthy tracing cannot be achieved, stop dependent implementation and request a supported-boundary decision. A finite model cannot pass this gate.
2. Confirm the four [module test seams](architecture.md#existing-test-interfaces) and the vertical-slice dependency plan before implementation.
3. Deliver a thin query/check path through one Plan predicate, the independent corpus, both real adapters, coverage, identity and complete JSON. Demonstrate a known violation surviving simultaneous unknown evidence.
4. Complete the other commands and semantic invariants, helper/runtime faults, safe initialization and Mermaid behavior.
5. Build all three archives and the npm/pub packages; run complete acceptance in clean target environments.

## Seam coverage and its limits

| Seam | Must catch | Does not establish alone |
| --- | --- | --- |
| Plan.load and returned queries | YAML/parser errors; empty plan; portable lexical paths; future overlaps; required public; direct versus transitive permission; owned/excluded/outside/unowned; sealed modules; exact pointers; catalogue/pagination/hash | Compiler extraction, physical target identity, process behavior or installed executable |
| Inspection.check on real projects | Corpus independent of compiler exclusions; zero/multiple/unknown contexts; unsupported kinds; final compiler targets; provenance; boundary precedence; public/re-export/parts/conditional branches; stable identity and input conflicts; known violations retained under incompleteness | CLI argument/stream contract and target OS coverage unless executed there |
| Bootstrap.initialize with temporary roots | Exactly two files; dry-run contents; preflight conflicts; exclusive-create race; second-write failure; own-file-only rollback and residual paths | Forced-crash atomicity, which is not promised; all platform filesystem semantics |
| CLI.run with captured streams | Grammar and options; complete deterministic JSON; status/exit precedence; clean stdout/stderr; help/version; declared safe Mermaid; command routing with the same predicates | Packaged AOT asset lookup, external-runtime discovery, actual process cleanup or clean-machine installation |

Fault-test dependencies exercise failure behavior through these seams. Real compiler, process, platform and extracted-archive runs are additional acceptance evidence, not substitute mocks or new public interfaces.

## Required evidence families

- Public schema plus semantic checks: all positive/negative fixtures, sorting, deduplication, exact-byte policy hash, references, range order, count arithmetic, candidate/descriptors, status/exit mapping, public-node detail, linked policy/edge predicates and independent protocol versions.
- Real Dart: prepared contexts/workspaces/nested packages; every supported conditional branch; import/export/part/part-of; missing inputs; Flutter import/dart:ui/parts/generated imports/cache absence. Retain physical source owners and independent facts.
- Real TypeScript: pinned actual compiler self-check; explicit tsconfig/extends; actual Program membership; aliases/workspace/package joins; supported configuration representatives; prepared `.d.ts` redirects; literal type-only/import-type/require/dynamic references; positioned unknowns for unsupported explicit references; no build or source-target guessing.
- Physical paths/provenance: symlink/junction refusal in corpus, supported resolver aliases, canonical containment, Unicode/case collisions, unchanged hardlink path semantics, installed versus repository/path provenance, missing/contradictory lock joins and real package-manager fixtures.
- Revalidation: changed bytes, absent target appearance, changed inventories, alias retargeting, cross-project contradictory observations, invalidation of affected facts and discovery while preserving independent violations. Empty/partly inaccessible corpus cannot claim false success.
- Runtime/helper: missing/wrong runtime or assets, request correlation/schema errors, limits at/exceeding boundaries, timeout/cancellation, exit plus EOF, bounded reap, and stopping future launches if termination is unconfirmed. A failed language retains the other language's usable result.
- Init/export: no implicit overwrite, fixed filenames, template comments only, `init --policy` fails before writes, precise planned/created/residual/conflict outcomes, safe Mermaid text and deterministic complete output with separate diagnostics.

Use the [contract route table](../../contracts/README.md) to select exact fixture sets; language and adversarial acceptance JSON are scenarios to execute against the implementation, not proof they already ran.

## Required release matrix

Every cell must build, extract and run the complete archive in a clean machine/VM matching its target:

- linux-x64: Ubuntu 24.04 LTS, glibc.
- macos-arm64: macOS 15, APFS.
- windows-x64: Windows 11 24H2, NTFS.

Each includes another cwd, spaces/Unicode in paths, relocating the extracted directory, missing Node/SDK, offline operation, no project-code execution, real compiler fixtures including Flutter, process/fault behavior and exact assets/version manifests. Native query/init/export must work without either external runtime; npm requires Node; pub requires pinned Dart to invoke its activated snapshot explicitly through global run. Neither route starts an additional analysis runtime for these commands. This specification alone does not certify any target. Release is blocked until all three pass or the user explicitly approves a narrower release scope.

## Required package-route acceptance

Execute the [package delivery acceptance](../../contracts/compatibility/delivery.md)
for actual packed npm local/global/cache routes and the 0.2.0 thin pub launcher
activated using --no-executables and invoked with dart pub global run
archway:archway. Keep script-disabled npm installation and offline warm use;
for pub this requires a prepared activated snapshot under the same SDK plus
verified native cache. Test SDK-switch and missing/stale-snapshot behavior
separately, including SDK recompilation and possible network access. Prove bounded one-target cold acquisition, safe archive extraction,
full pre-publication inventory verification, independent caches, concurrent atomic
publication, corruption refusal and manifest/executable warm hashing. Exercise
real installed commands and exact artifact inventories; injected transport/cache/
extraction seams remain private fixture controls. Native invocation retains the
existing compiler, runtime, filesystem and platform gates.

A genuine private hosted Linux fixture on Dart 3.13.3 passes activation without
generated aliases, explicit global-run snapshot dispatch, exact argv/streams/exit
propagation and offline execution with no HTTP. Actual Archway thin-wrapper
acceptance on all three platforms and hosted public installation remain gates.
No alias generation, launcher repair or setup/bootstrap workaround is allowed. Local injected
transport is not hosted-URL evidence. Native upload, real pinned hosted-URL cold
fetch, and registry publication are distinct ordered gates, with separate upload
and publication authorization. No local test authorizes publication.

## Scope boundaries

No hierarchy, HTML viewer/editor, symbol/dataflow control, new language, multiple assigned contexts per file, persistent inspection/result cache, daemon/server, MCP, plugin system, public embedding API, brew installer, custom dependency/bootstrap installer, automatic AGENTS/CI/editor changes, or automatically weakened policy. The pinned native installation caches required by the thin wrappers are permitted. Application tests remain separate from architecture checks.
