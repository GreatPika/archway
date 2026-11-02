# Archway v1 architecture

## Four modules

- **CLI** composes dependencies, parses arguments, owns public envelopes/versions, status/exit mapping and streams. `CLI.run(args, streams)` returns the exit code. It calls Plan, Inspection and Bootstrap. Mermaid is an internal CLI formatter over Plan's declared projection.
- **Plan** loads the exact policy bytes and owns validation, path normalization, immutable policy, module lookup, catalogue and dependency predicates. `loadPlan(RepositorySelection)` in `policy_loader.dart` returns PlanLoad. A valid Plan answers `owner`, `node`, `catalogue`, `allows` and `declaredProjection`. The file predicate is shared by path-mode queries and Inspection. Plan has no dependency on Inspection or SDKs.
- **Inspection** owns a complete `Inspection.check(RepositorySelection) → Report`. It loads Plan itself, enumerates the independent corpus, performs project/runtime discovery, runs the Dart analyzer adapter, validates evidence, evaluates reliable edges and revalidates all observed inputs. Invalid policy stops adapters. It owns Report, ProjectRequest and ProjectEvidence.
- **Bootstrap** owns `Bootstrap.initialize(root, template, dryRun) → InitResult`, exclusive creation of the two fixed startup files and explicit residual outcomes after failure, without automatic deletion. It neither derives architecture from source nor invokes Inspection.

CLI depends on Plan, Inspection and Bootstrap; Inspection depends on Plan and its Dart analyzer adapter. The adapter reports facts and uncertainty; it does not know policy decisions or CLI output shape. Types stay with their owning module. Do not add a shared catch-all models, services or utilities module, or a universal renderer.

## Internal libraries

The four owners above are responsibilities, not four large Dart libraries. Each
source file is an independent library with explicit imports; handwritten `part`
and `part of` directives are not used in the implementation. Analysis of user
projects containing Dart parts remains supported.

- **Plan:** `plan.dart` is the immutable query model. `policy_definition.dart`
  owns policy values/configuration; `repository_path.dart` owns lexical paths and
  deterministic text ordering. `policy_loader.dart` owns exact-byte reading,
  hash, semantic validation and load diagnostics; `policy_yaml.dart` and
  `policy_schema.dart` own syntax and closed shape validation. `Plan.validated`
  is an internal constructor whose caller must supply validated normalized
  values; the loader is its production caller. The model never imports its loader,
  filesystem I/O, YAML, Inspection or an analyzer.
- **Inspection:** `inspection.dart` orchestrates acquisition and revalidation;
  `assessment.dart` assigns acquired evidence and evaluates policy;
  `report.dart` owns results, diagnostics and ordering. `corpus.dart` inventories
  independent source scope. `observations.dart` captures/rechecks physical input
  identity; `input_observation.dart` holds its immutable factual value without
  filesystem operations. `project_evidence.dart` owns request/evidence values
  and source-kind classification. Assessment is independent of I/O and analyzer
  implementation, including through repository-owned imports.
- **Dart implementation:** `dart_adapter.dart` owns project/context lifecycle;
  `dart_runtime.dart` owns invocation-local SDK preparation/cache;
  `dart_context.dart` validates stable context descriptors;
  `dart_directives.dart` extracts direct dependency facts. Resources, part-owner
  discovery, package provenance and prepared Flutter recognition have concrete
  implementation owners. These libraries can use policy configuration and lexical
  path values, but cannot import policy evaluation, loading, CLI or report assembly.
- **CLI:** `cli.dart` composes commands. `invocation.dart` owns grammar/help,
  `cli_output.dart` owns the transport envelope, `mermaid.dart` formats the
  declared graph, and `export_file.dart` owns same-handle file output.
- **Bootstrap:** `bootstrap.dart` owns initialization outcomes and template;
  `startup_files.dart` owns the concrete opened-directory write operations.
  Native I/O remains the existing lower-level private implementation.

Imports and exports form an acyclic graph. No leaf imports the orchestration
library to reach a helper. Names visible between internal libraries are not a
supported embedding interface. There is no generic services/models bucket,
command class hierarchy, or hypothetical adapter framework.

Inspection keeps this sequence: all project discovery and contradictory input
observations; assignment and policy assessment with affected facts suppressed;
final input recheck; changed/cancellation diagnostics; completeness and report.
Late changes do not erase independently acquired findings or trigger a second
assignment pass. One runtime process guard and SDK preparation cache live for the
whole check; cached preparation observations are attributed to each project.

`test/module_structure_test.dart` checks these dependency rules and concrete
seams separately from behavioral acceptance. File size is not a correctness
criterion; each extraction must own a coherent responsibility behind a useful
interface.

## Installation boundary

The root executable package uses Dart's standard installation and code-asset
bundling. A small selection-only hook chooses one packaged ABI-2 bridge; NativeIo
binds it by the matching asset ID. SDK package/install mechanics own delivery,
not a new public module. There is no source-relative locator, runtime downloader,
wrapper cache or project-provided asset/compiler fallback. Native filesystem
semantics stay in their existing private owner. See [delivery](../../contracts/compatibility/delivery.md).

## Evidence boundary

ProjectRequest carries the full relevant corpus and explicit project configuration. ProjectEvidence reports contexts and membership for every expected file, file analysis status, reliable edges, positive/negative/directory/alias input evidence, and diagnostics. Candidate assignment is made only after all relevant project discovery. Context identifiers are stable and refer to descriptor tables, not traversal indexes. Native compiler details stay behind adapters.

Dart uses embedded analyzer and prepared package/SDK mappings. A verified external
Dart executable is queried without a shell under a five-second/64 KiB preflight
budget. Timeout, cancellation and unconfirmed cleanup preserve explicit failure
and block further runtime launches where required. Analyzer facts are not policy
decisions. No user code, plugin or preparation command runs during inspection.

Coverage, input identity, canonical paths, package provenance, target classification, context identity and invalidation are exact contracts in [assignment](../../contracts/assignment/design.md), [compatibility](../../contracts/compatibility/decisions.md), [package provenance](../../contracts/compatibility/package-provenance.md) and [public results](../../contracts/json/decision.md).

## Existing test interfaces

These are module seams for this implementation, not a promised embedding API:

1. `loadPlan` with temporary policy files, asserting resulting queries/diagnostics.
2. `Inspection.check` against real prepared projects, asserting complete reports and preserved independent evidence under failure.
3. `Bootstrap.initialize` in temporary directories, asserting both returned outcomes and filesystem contents.
4. `CLI.run` with captured streams and exit code, asserting the real public grammar and transport.

Prefer externally observable module results over internal call sequence tests. Internal production/fault-test dependencies may inject filesystem/process failures for timeout, residual-path and partial-write cases; they add no public seam and do not certify real compiler/runtime behavior. Pure algorithms remain tested through their owning module. The CLI is the sole supported external interface; no public compile/collect/assess pipeline, Dart embedding contract or plugin ABI is introduced.
