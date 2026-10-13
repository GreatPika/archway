# Archway v1 architecture

## Four modules

- **CLI** composes dependencies, parses arguments, owns public envelopes/versions, status/exit mapping and streams. `CLI.run(args, streams)` returns the exit code. It calls Plan, Inspection and Bootstrap. Mermaid is an internal CLI formatter over Plan's declared projection.
- **Plan** loads the exact policy bytes and owns validation, path normalization, immutable policy, module lookup, catalogue and dependency predicates. `Plan.load(RepositorySelection)` returns PlanLoad. A valid Plan answers `owner`, `node`, `catalogue`, `allows` and `declaredProjection`. The file predicate is shared by path-mode queries and Inspection. Plan has no dependency on Inspection or SDKs.
- **Inspection** owns a complete `Inspection.check(RepositorySelection) → Report`. It loads Plan itself, enumerates the independent corpus, performs project/runtime discovery, runs both language adapters, validates evidence, evaluates reliable edges and revalidates all observed inputs. Invalid policy stops adapters. It owns Report, ProjectRequest and ProjectEvidence.
- **Bootstrap** owns `Bootstrap.initialize(root, template, dryRun) → InitResult`, exclusive creation of the two fixed startup files, rollback and explicit residual outcomes. It neither derives architecture from source nor invokes Inspection.

CLI depends on Plan, Inspection and Bootstrap; Inspection depends on Plan and its Dart/TypeScript adapters. TypeScript Adapter owns the bundled Node helper process boundary. Adapters report facts and uncertainty; they do not know policy decisions or CLI output shape. Types stay with their owning module. Do not add a shared catch-all models, services or utilities module, or a universal renderer.

## Installation boundary

One small private installation-layout owner resolves assets from Archway's own package URI or canonical staged native executable. Bootstrap and Inspection consume its fixed paths; it is not a fifth public module or test seam. The 0.2.0 npm and separately staged pub launchers acquire one pinned native payload into independent user caches, then directly forward to the same AOT core. One generated release descriptor binds archive bytes and the root manifest. Acquisition validates the complete inventory before atomic publication; warm launch verifies manifest and executable hashes. The pub wrapper is activated with --no-executables and invoked through explicit dart pub global run, using its prepared snapshot under the same pinned SDK. No generated alias, launcher rewrite, setup fallback or new public module seam is introduced. Core source development keeps bin/archway.dart. The native payload uses the generated vendor TypeScript tree; no project/cwd compiler fallback is allowed. Explicit invocation trusts the installation even inside the inspected root, without weakening no-alias checks, external-runtime filtering or source-corpus coverage. See [package delivery](../../contracts/compatibility/delivery.md).

## Evidence boundary

ProjectRequest carries the full relevant corpus and explicit project configuration. ProjectEvidence reports contexts and membership for every expected file, file analysis status, reliable edges, positive/negative/directory/alias input evidence, and diagnostics. Candidate assignment is made only after all relevant project discovery. Context identifiers are stable and refer to descriptor tables, not traversal indexes. Native compiler details stay behind adapters.

Dart uses embedded analyzer and prepared package/SDK mappings. TypeScript uses one pinned Compiler API helper process per project. Its private v2 protocol requires ordered raw symlink-hop witnesses on every input and uses one UTF-8 JSON request and response with EOF, no streaming or retries. Validate exact versions/correlation, closed schema, paths, source spans, evidence references and completeness before accepting any response.

The helper preflight budget is 5 seconds and 64 KiB. Request limit is 8 MiB; stdout 64 MiB; stderr 256 KiB. One project has 120 seconds from spawn to exit plus EOF, then at most 2 seconds cleanup. Exceeding limits, nonzero exit or an invalid envelope discards that project's response. A valid failed response with exit 0 can retain verified facts. Unconfirmed termination blocks later helper launches in the invocation. Spawn uses argv without shell, cleared loader influence and verified external runtimes; project wrappers/code are not executed.

Coverage, input identity, canonical paths, package provenance, target classification, context identity and invalidation are exact contracts in [assignment](../../contracts/assignment/design.md), [compatibility](../../contracts/compatibility/decisions.md), [package provenance](../../contracts/compatibility/package-provenance.md), [helper protocol](../../contracts/helper/protocol.md) and [public results](../../contracts/json/decision.md).

## Existing test interfaces

These are module seams for this implementation, not a promised embedding API:

1. `Plan.load` with temporary policy files, asserting resulting queries/diagnostics.
2. `Inspection.check` against real prepared projects, asserting complete reports and preserved independent evidence under failure.
3. `Bootstrap.initialize` in temporary directories, asserting both returned outcomes and filesystem contents.
4. `CLI.run` with captured streams and exit code, asserting the real public grammar and transport.

Prefer externally observable module results over internal call sequence tests. Internal production/fault-test dependencies may inject filesystem/process failures for timeout, rollback and partial-write cases; they add no public seam and do not certify real compiler/runtime behavior. Pure algorithms remain tested through their owning module. The CLI is the sole supported external interface; no public compile/collect/assess pipeline, Dart embedding contract or plugin ABI is introduced.
