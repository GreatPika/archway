# Archway v1: implementation contract

## Navigation

| Task | Normative source | Verification |
| --- | --- | --- |
| CLI, JSON, errors, init, YAML, public entrypoints | `json/decision.md`, `json/*.schema.json` | `json/validate_contract.dart`, `../test/contracts/public_contract_test.dart`, `../test/contracts/public_boundary_test.dart` |
| File-to-project assignment | `assignment/design.md` | `assignment/assignment_reference.dart`, `../test/contracts/assignment_test.dart`, `assignment/empty-corpus-acceptance.json` |
| Runtime, platforms, paths | `compatibility/decisions.md` | `compatibility/lexical_reference.dart`, `../test/contracts/lexical_reference_test.dart`, `compatibility/adversarial-cases.json`, `compatibility/observation-acceptance.json` |
| npm/pub/native delivery | `compatibility/delivery.md` | Real packed-install and platform gates in that contract |
| Package-target provenance | `compatibility/package-provenance.md` | Real package-manager fixtures in that contract |
| Private TypeScript helper | `helper/protocol.md`, `helper/*.schema.json` | `helper/validate_contract.dart`, `../test/contracts/helper_contract_test.dart`, `../test/contracts/helper_protocol_v2_test.dart`, `../test/contracts/helper_transport_test.dart` |
| Re-exports, Dart parts, TypeScript redirects | `assignment/design.md`, `helper/protocol.md`, `entrypoints/language-notes.md` | `entrypoints/language-acceptance.json` |
| Cross-contract regressions | Normative sources above | `../test/contracts/cross_contract_test.dart`, `../test/contracts/entrypoint_regressions_test.dart` |

## Verify the bundle

From the repository root, prepare dependencies with `dart pub get`, then run `dart contracts/run_tests.dart`. Use the pinned Dart SDK and developer dependencies in `pubspec.yaml` and `pubspec.lock`; schemas use JSON Schema Draft 2020-12. The runner first verifies `manifest.json`: every bundle file except the manifest itself and ignored bytecode caches must be listed with its current SHA-256. Regenerate the inventory after contract amendments, retaining version metadata. The runner executes an explicit inventory of Dart test groups and rejects changes to helper seed bytes. Regression results are printed to stdout, not persisted in the bundle. Helper cases are derived in memory from two seed fixtures; the fixtures remain unchanged.

Individual groups can also run with `dart test test/contracts/public_contract_test.dart`. This focused command does not replace the aggregate manifest and seed-immutability checks.

JSON Schema defines structure; normative text defines semantic constraints, including correlation, ordering, identity, arithmetic, and ownership. The schema does not replace these requirements. Fixtures and finite models supplement the contract and do not implement Archway.

`language-acceptance.json` and `adversarial-cases.json` define expected implementation behavior. Real Dart/TypeScript compilers, the CLI, target-OS filesystems, processes, and installation archives require separate acceptance on pinned versions before release.

Policy version and public schema_version are 1; private helper protocol_version is 2. Every node requires `public`: `[]` or a list of exact file paths; omitting the field is unsupported. Exact access and versioning rules are in `json/decision.md`.

Development order and release gates: [Implementation and acceptance](../docs/spec/acceptance.md).
