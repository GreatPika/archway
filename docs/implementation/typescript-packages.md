# TypeScript inspection

Use this guide for prepared configuration, reference interpretation and npm/pnpm
origins. The baseline is Node 24.21.0 and bundled TypeScript 5.9.3, public schema
and policy 1, private helper protocol 2. Checks only read prepared files; package
installation, builds, scripts and plugins belong to separate preparation.

## Compiler boundary

Actual JSON/JSONC configuration, local extends, paths and baseUrl use compiler
resolution with paths relative to the defining configuration. Compiler-excluded
files remain in the independent corpus. Module/JSX modes are compiler inputs,
not a small hand-written whitelist; ordinary type errors do not erase reliable
reference evidence. Project references retain actual declaration SourceFiles
(.d.ts/.d.mts/.d.cts); declaration maps never redirect them to source. Missing
required output stays incomplete and check emits no build artifacts. Solution
references do not implicitly add policy projects.

Import, import-equals, re-export, import-type, literal dynamic import and the
bounded literal-require route retain occurrences, direct targets and type-only
flags. Native import/require mode and valid type-reference resolution-mode apply
per occurrence. Computed references, triple-slash references, external-module
augmentations (including nested ambient ones) and invalid mode attributes remain
positioned unknowns; ordinary global declarations/symbols alone do not.

TypeScript 5.9.3 collects require Program dependencies in JavaScript, not ordinary
TypeScript; JavaScript analysis is disabled. For unbound one-argument literal
require, the helper uses the compiler's CommonJS resolver with the containing
SourceFile options and requires an existing actual Program SourceFile. It adds no
roots/Program or synthetic membership. Require-only targets outside the Program
and transparent wrappers remain unknown. Bound require must pass the actual
checker declaration/signature provenance checks below; its name alone is no proof.

## Origin evidence and limits

packages.cjs joins npm's exact install row and effective source to the Program
target, installed manifest and canonical root. Local copies also match source
file hashes. pnpm.cjs joins importer or verified parent-instance snapshots,
including peers, to exact encoded installed instances. Selected/installed locks,
.modules.yaml, workspace configuration and relevant local manifests are observed.
No same-name search substitutes for a real route.

node-origin.cjs checks checker declarations and effective call signatures,
rejecting local loaders, shadowing and conflicting augmentation. Node builtins
also need pinned-runtime recognition. Self-reference requires compiler identity
and own-manifest exports/types mapping. Parent validation checks input roles,
manifest identity, canonical root and builtin declaration evidence. It is not a
second lock classifier and cannot detect every forged helper response with valid
evidence roles. Independent final revalidation covers observed inputs;
conflicting observations cannot become fresh facts.

Simple effective root overrides take precedence. npm direct overrides must equal
the direct request after resolving $dependency. Invalid present shrinkwrap,
conflicting versions/aliases and stale registry rows under Git/URL requests fail
closed. Contextual/version-qualified overrides and unrecognized manager formats
remain unknown. Stable ranges use bundled TypeScript Version/VersionRange;
nonexact prerelease requests remain unknown because that implementation includes
prereleases. Locked dist-tags represent prepared selections, not registry queries.

The pnpm URL join covers exact tarballs, configured-registry canonical tarballs,
and pinned GitHub-to-exact-commit codeload normalization. Other hosted-Git
normalizations remain unknown. These origins establish prepared consistency,
not installed-byte authenticity or complete compiler-feature coverage.

## Pinned sources and licenses

- npm format and shrinkwrap precedence: https://docs.npmjs.com/cli/v11/configuring-npm/package-lock-json/
- pnpm 9.15.9 dependency-path encoder: https://raw.githubusercontent.com/pnpm/pnpm/v9.15.9/packages/dependency-path/src/index.ts
- pnpm 9.15.9 hash: https://raw.githubusercontent.com/pnpm/pnpm/v9.15.9/packages/crypto.base32-hash/src/index.ts
- pnpm installed-layout manifest: https://raw.githubusercontent.com/pnpm/pnpm/v9.15.9/pkg-manager/modules-yaml/src/index.ts
- The small CJS encoder adaptation carries the upstream MIT notice under
  assets/typescript/licenses/pnpm-MIT.txt. MD5 only reproduces a filename.
- yaml 2.8.1 official tarball: https://registry.npmjs.org/yaml/-/yaml-2.8.1.tgz
  SHA256 195759b97d3f2e6085474549c069397ad7af6160be6d7c87442b8c47cb724063.
  SRI is pinned in the helper package-lock. ISC notice is retained. Parsing is
  data-only, rejects duplicate keys/custom tags, bounds aliases/size/depth and
  converts maps to own-key objects.

## Fixtures and reproduction

Preparation used npm 11.19.0 and pnpm 9.15.9 with scripts disabled and pnpmfile
hooks disabled. [Base preparation](../../test/fixtures/node-packages/fixture-preparation.md)
and [additive fixtures](../../test/fixtures/node-packages/addon-fixtures.md) retain regeneration,
official URLs, integrity records, licenses and file/link manifests. Their scripts
are maintainer-only and never run by check. Committed archive identities:

- prepared.tar.gz: `9792e5f10186984f175c8720480ed361dfdab8e611bee9f1f7195e1b183ad2bd`
- addon.tar.gz: `5b4c7d96b6db597dc59b449ca7d826d60271bc23e831b7caa94c6b68bc55eda9`
- npm-override.tar.gz: `fd7b3d0f099c107e7d12b272f26f244cd3ea79042db87b4003dae6af42fcb576`

The override archive retains npm-generated $ansi-regex override output and evidence.
Coverage includes npm v2/v3, aliases, shrinkwrap, workspace/local/HTTPS/Git, pnpm
full/hashed peers and filename truncation, copied/injected local packages, moved
store, parent snapshots, missing/conflicting metadata and input mutations.
Same-byte lock symlink retargeting still produces INPUT_CHANGED.
Source package tests use the shared Dart offline extractor in
`test/support/node_package_fixtures.dart`. It preserves archive bytes and actual
hardlinks, creates native relative directory symlinks last, and verifies their
traversal before inspection, including on Windows. Process suites use the same
Dart extractor.
Local extractor results do not establish native platform acceptance.

From repository root, with prepared dependencies/assets and native bridge:

```sh
dart --suppress-analytics test test/typescript_references_test.dart test/typescript_unknowns_test.dart test/typescript_projects_test.dart test/typescript_configuration_test.dart test/typescript_require_binding_test.dart test/typescript_packages_test.dart test/typescript_package_wire_test.dart --concurrency=1
```

For actual AOT package/schema/stream checks, use the shared commands and prepared
pub/Git prerequisites in [Dart reproduction](dart-check.md#reproduction). These
Linux development checks do not certify target OS cells or installation routes;
see [CI scope](../../tool/ci/README.md) and [installation](installation-layout.md).

Pinned implementation references:
- [npm override rules](https://docs.npmjs.com/cli/v11/configuring-npm/package-json/#overrides)
- [pnpm Git resolver](https://github.com/pnpm/pnpm/blob/v9.15.9/resolving/git-resolver/src/index.ts)
