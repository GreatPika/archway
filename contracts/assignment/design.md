# Source-to-project and context assignment: decision v1

Normative assignment contract. No YAML extensions.

## Normative rule

Inspection independently enumerates corpus C: existing regular files with recognized code extensions in scope minus exclude. Compiler directories, .gitignore, analyzer exclude, and generated markers do not reduce C. A policy-excluded source is not analyzed as a source, but a confirmed relation to it remains a violation. An area missed because traversal failed yields incomplete, not a zero-sized corpus. Symlinks and aliases follow the separate physical-path contract.

Empty projects and nodes do not cancel enumeration of C. json/decision.md defines EMPTY_PLAN and status for an empty or unknown corpus; combined policy/corpus acceptance cases are in empty-corpus-acceptance.json.

The Dart-only corpus contains .dart files (case-sensitive), including generated .dart sources. Directory scopes ignore non-Dart files, including JS/TS tooling. An explicit non-Dart file scope receives UNSUPPORTED_SCOPE_FILE as a warning. Ordinary data/assets are not classified as code merely because they are imported. v1 does not promise to recognize unknown extensions as languages; an explicitly requested scope-file of unknown type receives the UNSUPPORTED_SCOPE_FILE warning, but ordinary data files do not automatically become unknown.

For every f in C, construct candidate set K(f) from (project_id, context_id) pairs rather than module ownership. A context can be assigned only when exactly one supported candidate is confirmed and discovery has completed for all projects of that language. Zero candidates yields ANALYSIS_CONTEXT_MISSING; multiple candidates yield ANALYSIS_CONTEXT_AMBIGUOUS. YAML order, nearest configuration, deepest directory, and identical effective analyzer/context options do not resolve ambiguity. If discovery fails for another project of the same language, uniqueness is unproven: ANALYSIS_CONTEXT_DISCOVERY_FAILED; retain positive candidates.

Incompleteness does not erase reliable observations and violations from successfully read contexts. Context-tagged facts for an ambiguous file may be retained as partial evidence; that file does not count as fully analyzed. Resolutions from two contexts must not be combined into a supposedly complete interpretation.

## Dart

1. One YAML project creates one AnalysisContextCollection with includedPaths equal to normalized absolute package_roots and the pinned SDK. Normalize duplicate roots within a project. Retain nested roots in the declaration; analyzer performs the actual partitioning. Do not assume one package root equals one context.
2. For every C file under one of the project's declared package_roots, enumerate all collection.contexts where contextRoot.isAnalyzed(f) is true. Do not rely on the first contextFor: it can hide multiple candidates. Each such context is a candidate. Identify a context by its project and a stable description of root/includedPaths/excludedPaths/package-config/options inputs/SDK, not an object address or ordinal.
3. Ordinary prepared pub packages are supported; a shared package_config for a pub workspace is allowed if analyzer selected it and every declared package/path has confirmed configuration. package_roots defines project participation, not necessarily the location of package_config: that file may be at the workspace root. Missing, corrupt, or selected-SDK-incompatible package_config yields incomplete. No automatic pub get.
4. Nested packages and local analysis_options within one YAML project are supported exactly through discovered analyzer context/options mappings. New analysis_options do not necessarily mean a new context. If analyzer excludes a file/hidden directory, independent C retains the file; no candidate = incomplete. Do not substitute options or silently disable exclude.
5. Different YAML Dart projects with overlapping areas receive no depth-based priority: even an identical discovered analyzer context belongs to different project_id values and yields ambiguity. Repeating a root across projects also yields ambiguity for included files.
6. Analyzer may discover an undeclared nested package under a declared root; it remains in that YAML project. A file outside all declared roots does not become a project source merely because it is imported. A resolved local target is still checked for scope/owner; its own C entry requires its own assignment.
7. .g.dart and other generated .dart files are ordinary sources; do not run build_runner. Ordinary parts with a single confirmed containing library are supported; multiple-library parts, unresolved part of, and generator/augmentation requiring missing inputs yield unknown/incomplete. Account conservatively for all conditional import/export branches in context, without executing code.

Bazel/GN/custom workspaces and plugin-dependent/generated virtual sources are not ordinary pub contexts and yield explicit unsupported configuration. Flutter depends on a separate SDK matrix row; analyzer alone cannot establish confirmed support. The contract does not run user analyzer plugins to supply missing semantics.

## Algorithm and evidence

A. Fix C before adapters; retain enumeration gaps. B. Pass each project the full supported corpus for its language as candidates to check, not already assigned files: assignment is not yet known. Inspection reconciles all project results before assigning contexts. Obtain discovery_complete and its contexts/inputs. C. Construct complete K(f), sorted by project_id/context_id. D. Assign 0/1/many with unknown candidates taken into account. E. Extract facts; check owners/edges using the unified Plan. F. Reconcile coverage strictly against C: one file record per path, expected = |C|, analyzed <= expected; a missing/extra record or unknown project/context is an evidence error. An unknown traversal area additionally prevents analysis_complete even when analyzed=expected for the known portion. G. Check for changes to all read config/package/source inputs and for new/disappeared files; incompleteness preserves confirmed violations.

Public coverage requires file path, assignment status, all discovered project/context candidates, discovery completeness, and reasons for incompleteness; exact field names/enums belong to the shared JSON Schema. Failed discovery must not invent unknown candidates: list actual positive candidates and unresolved project ids. Diagnostics have nullable rule_pointer/source_range and recovery_hints. Emit context descriptors once in coverage.projects[].contexts; versions and hashes of actually read configurations remain in input_identity and runtime metadata. A context does not change the owner.

## API sources

- AnalysisContextCollection: https://pub.dev/documentation/analyzer/latest/dart_analysis_analysis_context_collection/AnalysisContextCollection-class.html — a collection contains multiple contexts; contextFor may throw StateError when none exists.
- ContextRoot: https://pub.dev/documentation/analyzer/latest/dart_analysis_context_root/ContextRoot-class.html — isAnalyzed accounts for included/excluded; the context carries packages/options.
- Analyzer source: https://raw.githubusercontent.com/dart-lang/sdk/main/pkg/analyzer/lib/src/dart/analysis/context_locator.dart — the locator partitions package/workspace contexts and supports local options mappings; this explains behavior rather than replacing pinned-version tests. Moving main and latest docs do not prove compatibility of a particular release archive.

## Verify this decision

fixtures.json contains 26 adversarial decision fixtures. From the repository root, `dart test test/contracts/assignment_test.dart` checks assignment_reference.dart's pure cardinality/discovery function and context descriptor encoding; `dart test test/inspection_test.dart` checks the corpus-preservation invariant. This is an executable reference for the assignment model, not Dart analyzer. Release acceptance also requires real fixtures on pinned versions, packages, and operating systems.

### Exact public assignment fields and context_id

Aligned with JSON Schema: coverage.files[] contains path, nullable project_id/context_id, candidates:[{project_id,context_id}], assignment (assigned/missing/ambiguous/unsupported/failed), analysis (complete/partial/failed/not_attempted), discovery_complete:boolean, unresolved_project_ids:string[]. The last list names declared projects of this language whose discovery has not been proven complete; it is sorted and duplicate-free. project_id/context_id are non-null only for assigned. facts.edges[] carries both project_id and context_id so partial contextual facts are not mixed.

Dart context_id = "dart:" + project_id + ":" + hex(SHA-256(descriptor)). Descriptor is a JSON object with keys root, included_paths, excluded_paths, package_config_path (string|null), options_paths, sdk_version (exact version string); paths follow the same path contract, the repository root is replaced by repository-relative identity, and external inputs use absolute canonical file:/// URIs. Use "./" for the repository root itself; other repo-relative paths have no ./ prefix or trailing / and use / separators. included_paths/excluded_paths/options_paths are arrays of unique strings sorted by Unicode scalar values. options_paths contains actually applicable option sources/mappings, not only the nearest file. Sort JSON keys lexicographically; use compact UTF-8 JSON, no ASCII-escaping of Unicode, no whitespace/BOM, standard JSON escapes, and no trailing LF. SHA-256 is lowercase hex, all 64 characters. No object address, process id, or collection index. Full descriptors are in coverage.projects[].contexts, input-content hashes in input_identity; the ID does not replace freshness checks. Changing options mappings may change Dart context_id.

The contexts table appears exactly once in each coverage.projects[]: [{context_id, descriptor}]. project_id and adapter come from the project row and are not duplicated inside descriptor. Dart descriptor has exactly the six listed fields; adapter/project_id are absent from the hashed object. SDK is included in the Dart descriptor/hash as the explicitly selected execution context, while detailed SDK/adapter/runtime provenance remains in the shared identity. All candidates and facts reference declared contexts of existing projects; dangling references are forbidden.


## File-level public entrypoints: v1 language details

A confirmed relation belongs to the physical source file and the directly specified module/library target after standard compiler file/reference redirect. The final declaration file of an imported symbol is a different entity: following symbol aliases does not replace the direct target. A public barrel exporting a private file of the same owner remains a valid entrypoint. Check each of its imports/re-exports separately; a foreign-private re-export violates the rule on its own relation. A chain A → B/public → C/public creates no synthetic A → C relation and requires no transitive allows. The contract does not restrict the origin of symbols, types, and values behind an allowed API.

Dart preserves the physical source and its owner for part/part_of rather than substituting the containing library. Confirmed local part/part_of relations use the same directed allows + exact public target rule; there is no new single-owner requirement for the whole library. Resolve named part of only through a proven unique containing library, not as a path. Public remains a lexical file list: a part file may be listed without AST checks in plan/query, but this does not make an invalid standalone import valid Dart; unreliable interpretation yields incomplete while preserving independently proven facts. Symbol privacy inside an allowed cross-owner library is not an Archway guarantee.

For Dart import/export, check every default/conditional URI branch conservatively, including branches not selected by the current platform. Do not substitute selected importedLibrary for each branch's target. An unresolved branch yields incomplete without erasing a violation in another proven branch; show/hide/as/deferred do not change the file-level target.

Language acceptance specifications require verification against the pinned Dart analyzer.



## Reuse within an invocation

Within one check, create each discovered Dart analyzer context once and use them for both membership and fact extraction. Read data may be reused only within this invocation; there is no persistent cache. Do not overwrite repeated contradictory observations. Final independent reconciliation of inputs and the Inspection corpus is mandatory.
