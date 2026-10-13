# Bundled TypeScript helper

The parent launches `helper.cjs` using Node 24.21.0. One private protocol-v2
request creates one TypeScript 5.9.3 Program. Public schema and policy remain v1.
Only bundled tool modules execute. Project configuration and package metadata
are data; check never installs, fetches, builds, emits, invokes Git or runs hooks.

From the repository root, maintainers run `bash tool/prepare_typescript.sh` with
npm available. The script consumes this directory's pinned package lock, runs
`npm ci --ignore-scripts --no-audit --no-fund` in a temporary directory, and
copies the complete, unmodified TypeScript 5.9.3 and YAML 2.8.1 npm packages to
`vendor/typescript/` and `vendor/yaml/`, including compiler libraries and licenses.
Source development and release staging use this same generated tree. Ship all
`.cjs` modules, package manifests, Markdown evidence, licenses, and the entire
`vendor/` directory;
package assemblers must explicitly retain this generated output.

Preparation is an explicit maintainer step, never an install hook or a runtime
operation. Runtime loads only these fixed vendor paths, with no `node_modules`,
project-package or network fallback. The parent verifies every owned loadable
module and both dependency trees are ordinary, unaliased tool-installation files,
independent of the inspected repository. YAML is pinned to 2.8.1 (ISC); npm's lock
pins its official tarball SRI. No project-provided parser can replace it.

Package classification starts with the actual final Program target and resolver
lookup route. npm lock v2/v3 joins the exact installed row, effective manifest
source, installed manifest, physical mapping and origin. Shrinkwrap wins and its
absence is observed; hidden npm locks are never a fallback. pnpm 9.15.9 lock 9.0,
isolated layout 5 joins importer or parent-snapshot refs, complete peer identities,
package resolution, installed lock and actual store instance. `.modules.yaml`
supplies moved-store paths and injection metadata. An upstream-derived filename
encoder validates an instance; directory names never imply origin. Its MD5/base32
operation reproduces pnpm filenames and provides no authenticity guarantee.

Registry/HTTPS/pinned-remote-Git origins are external. Proven workspace and local
file/link origins remain local, including copied installs and outside-root paths.
Self imports require compiler package identity plus the source scope's own
manifest and matching exports/types mapping. Node builtins require the pinned
runtime identity and actual checker ambient-module declarations from proven
installed `@types/node`. Bound require additionally proves its variable, callable
interface and every effective call declaration; shadowing and conflicting local
augmentation remain unknown. Require never adds files to the Program.

Missing, unsupported or contradictory joins affect the reference requiring them.
Independent local facts survive. This is prepared-metadata consistency, not
artifact authentication or an atomic snapshot. Complex version/context-specific
overrides and unsupported layouts remain incomplete rather than inferred.

Filesystem tracing starts before compiler loading and records exact bytes,
negative probes, inventories and ordered alias witnesses. Classifier inputs are
also direct fact evidence. The parent validates envelope/evidence roles and
manifest identity/target-root consistency, then independently rechecks all inputs.
A changed or deleted manifest uses changed-input semantics. A fully forged helper
response with matching roles is not independently reclassified by the parent;
the shipped, guarded helper owns the exact package-manager joins.

See [compiler evidence](AUDIT.md), [licenses](licenses/), and the
TypeScript inspection guide (source-checkout-only repository-root path:
`docs/implementation/typescript-packages.md`)
for source provenance and Linux development test commands. See the guide's linked
CI and installation documentation for platform and release-installation coverage.
