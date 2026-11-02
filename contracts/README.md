# Archway Dart-only implementation contract

Policy and public schema versions remain 1. Valid Dart policies retain their
semantics; TypeScript project declarations are unsupported. Legacy nullable
`tool_versions.typescript_adapter`, `node` and `typescript` keys remain present
and null. Private helper delivery/protocol is removed.

| Concern | Normative source | Verification |
| --- | --- | --- |
| CLI, JSON, init, policy, public entrypoints | `json/decision.md`, `json/*.schema.json` | `json/validate_contract.dart`, `test/contracts/public*_test.dart` |
| Project/context assignment | `assignment/design.md` | `assignment/assignment_reference.dart`, assignment tests |
| Runtime, platforms, paths | `compatibility/decisions.md` | lexical/path reference and actual platform tests |
| Standard Dart installation | `compatibility/delivery.md` | actual Git install/update/uninstall and installed command tests |
| Package provenance | `compatibility/package-provenance.md` | genuine prepared Dart/Flutter fixtures |
| Re-exports, conditional URIs and parts | `entrypoints/language-notes.md` | language acceptance scenarios and real Dart tests |

From the repository root, prepare dependencies with `dart pub get`, then run
`dart contracts/run_tests.dart`. The aggregate runner verifies every bundle file's
SHA-256 against `manifest.json` before its explicit suite inventory. Regenerate
that inventory after amendments; retain policy/public version metadata and advance
artifact/design revisions appropriately.

Schemas define structure; normative text defines semantic constraints, ordering,
identity, arithmetic and ownership. Finite fixtures are not proof of real analyzer,
CLI, filesystem or installed-platform acceptance. Some neutral policy/path/edge
fixtures use `.ts` names or generic historical fact kinds: they protect portable
semantics, not support for TypeScript analysis. Dart context fixtures exercise
descriptor/hash semantics and may retain historical `sdk_version` values; they
do not establish current runtime support. Read [acceptance](../docs/spec/acceptance.md)
for the additional measured gates. Missing/unknown results must never be reported as zero
failures or passed platform coverage.

The aggregate runner hashes the acceptance-scenario JSON files; it does not execute
every scenario in `compatibility/adversarial-cases.json`,
`compatibility/observation-acceptance.json` or `entrypoints/language-acceptance.json`.
Their verification references identify separate runtime tests where available.
`test/dart_acceptance_examples_test.dart` checks the language inventory and executes
exactly the `dart-public-without-allows` and `dart-private-sameowner` source examples
through prepared Dart inspection. Other rows remain specifications unless their
corresponding integration or platform tests have actually run.
