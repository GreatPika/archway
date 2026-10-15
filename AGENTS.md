# Working on Archway

Repository specifications and contracts are authoritative. Keep product decisions,
contracts and acceptance criteria consistent; a conflict blocks dependent work.
Keep preparation separate from inspection, and distinguish implemented behavior
from measured platform/route acceptance.

## Read by task

- Product behavior or scope: [requirements](docs/spec/requirements.md).
- Module boundaries or test interfaces: [architecture](docs/spec/architecture.md).
- Implementation or release evidence: [acceptance](docs/spec/acceptance.md).
- Exact fields, precedence, schemas or fixtures: [contracts](contracts/README.md).
- Package layout or installation acceptance: [package delivery](contracts/compatibility/delivery.md).
- TypeScript compiler/configuration/package evidence: [TypeScript guide](docs/implementation/typescript-packages.md).
- Dart analyzer/pub/workspace/Flutter evidence: [Dart guide](docs/implementation/dart-check.md).
- Filesystem identity, alias handling or native ABI: [native/path guide](docs/implementation/native-io.md).
- Runtime budgets, cancellation or process failures: [runtime guide](docs/implementation/runtime-failures.md).
- Assembly, packaging or installed asset lookup: [installation guide](docs/implementation/installation-layout.md).
- Native probes and what CI results establish: [CI guide](tool/ci/README.md).

## Contributing

Use test-driven development for behavior changes. Review changes against a fixed
base, checking repository standards and acceptance criteria separately. Fixture
validation alone does not establish compiler, platform, process, CLI or
installation acceptance; report what was actually verified.

Specs and tickets live in [GitHub Issues](https://github.com/GreatPika/archway/issues).
Close work only after its acceptance criteria pass and the changes are integrated.

## Checks

After preparation, run `dart --suppress-analytics analyze` and
`dart --suppress-analytics test`. Fixture prerequisites are in the inspection guides.
