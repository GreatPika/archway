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
- Any implementation or review: [approved workflow](docs/agents/workflow.md), including approval gates, bounded delegation, TDD and fixed-base reviews.
- TypeScript compiler/configuration/package evidence: [TypeScript guide](docs/implementation/typescript-packages.md).
- Dart analyzer/pub/workspace/Flutter evidence: [Dart guide](docs/implementation/dart-check.md).
- Filesystem identity, alias handling or native ABI: [native/path guide](docs/implementation/native-io.md).
- Runtime budgets, cancellation or process failures: [runtime guide](docs/implementation/runtime-failures.md).
- Assembly, packaging or installed asset lookup: [installation guide](docs/implementation/installation-layout.md).
- Native probes and what CI results establish: [CI guide](tool/ci/README.md).

## Issue tracker

Specs and tickets live in GitHub Issues for `GreatPika/archway`. Verify the repository
and remote before the first write. Use authenticated GitHub connector operations,
or `gh` when installed and authenticated for this repository; never copy credentials
between tools. Inspect supported arguments before an operation, and report a blocker
if neither authorized route supports it. Resolve issue versus PR references before
acting; PRs are not a request/triage surface.

- Read the issue body, comments, state and relevant relationships before acting.
- Publish one issue per spec and one per approved implementation ticket. Link tickets as sub-issues where supported; otherwise use `Part of #<parent>` and a parent child-task list.
- Prefer native blocking relationships, with verified issue database IDs when required, not issue numbers or node IDs. Otherwise use `Blocked by: #<number>, ...` in the child body.
- A ticket is ready only after its blockers pass acceptance and are integrated; use actual issue state and integration evidence.
- No triage skill or label vocabulary is configured. Record `Status: ready-for-agent`, `in-progress`, `blocked`, or `done` in the body; do not create labels implicitly.
- The orchestrator claims tickets before delegation and prevents duplicate claims. Comments carry concise decisions, evidence and commit pointers rather than copies of source documents.
- Close tickets only after acceptance passes and work is integrated. Do not close or materially rewrite a parent spec while publishing children.
- External communications, assignments, PR creation and issue writes require the user's authorization. A skill example grants none; “publish to the issue tracker” means only the specifically authorized issue create/update.

## Domain terms and decisions

Use root `GLOSSARY.md` and `docs/adr/` for the single domain context. Before exploring
an area, read the glossary and relevant ADRs if present. Create them only for a
resolved term or qualifying decision; missing files need no placeholders or warning.
The glossary records vocabulary, not implementation plans. Use canonical terms in
discussion, issues, hypotheses, tests and code; verify a real vocabulary gap before
adding a synonym. Follow the pinned `domain-modeling` discipline for changes. If a
proposal conflicts with an ADR, explain the conflict and why reopening it may be
warranted before changing the decision.

## Checks

After preparation, run `dart --suppress-analytics analyze` and
`dart --suppress-analytics test`. Fixture prerequisites are in the inspection guides.
Python process/schema checks need `jsonschema`.
