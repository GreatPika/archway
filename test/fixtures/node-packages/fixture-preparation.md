# Prepared npm and pnpm provenance fixtures

Prepared using Node v24.21.0, npm 11.19.0, and official pnpm 9.15.9. All installs disabled package lifecycle scripts; pnpm additionally used `--ignore-pnpmfile`. Each fixture contains actual package-manager lock/installed metadata, complete installed package files and licenses, a minimal TypeScript entrypoint, and tsconfig.

## Committed archives and offline verification

The committed `prepared.tar.gz` contains the base fixtures, preparation scripts,
`verify-prepared.mjs`, the YAML parser and `evidence/`. Its SHA256 is
`9792e5f10186984f175c8720480ed361dfdab8e611bee9f1f7195e1b183ad2bd`.
The archived preparation notes call this same snapshot `prepared-fixtures-v2.tar.gz`.
[addon-fixtures.md](addon-fixtures.md) describes the separate `addon.tar.gz` cases and verification.
The npm override snapshot is documented in the
[inspection guide](../../../docs/implementation/typescript-packages.md#fixtures-and-reproduction).

From the repository root, with Node 24.21.0 on PATH and a tar implementation that
preserves symlinks, extract into a disposable directory and verify offline:

    fixtures="$(mktemp -d)"
    tar -xzf test/fixtures/node-packages/prepared.tar.gz -C "$fixtures"
    node "$fixtures/verify-prepared.mjs"

The verifier writes its evidence manifest in that extracted directory. It does
not modify the committed archive. Run the add-on verifier in a separate extracted
tree so its `evidence/` files do not overwrite base provenance.

## Base fixtures

- `npm-ambient-node`: exact official @types/node 24.10.0 and undici-types 7.16.0, plus ansi-regex 6.1.0. The source selects Node ambient types and uses type/value imports from node:fs, require('node:fs'), and require('ansi-regex'); package scripts remain unexecuted.
- `npm-git`: official chalk/ansi-regex repository pinned to registry gitHead f338e1814144efb950276aac84135ff86b72dc8e. Real npm output canonicalized requested git+https to git+ssh in resolved, preserving the exact commit.
- `npm-v3-small`: registry ansi-regex 6.1.0, npm lock v3.
- `npm-v2`: registry ansi-regex 6.1.0, npm lock v2.
- `npm-alias`: fixture-alias is a real npm alias of ansi-regex 6.1.0.
- `npm-tarball`: ansi-regex requested by its official HTTPS tarball URL.
- `npm-shrinkwrap`: actual npm shrinkwrap output; add a conflicting package-lock only in a test derivative to exercise precedence.
- `npm-workspace`: local `packages/local` linked by npm workspace install.
- `npm-file`: `file:../outside-local` copied by npm `--install-links`; actual installed package is a directory inside the fixture. Expected local, not external; actual compiler target is inside root.
- `npm-path`: the same outside source installed as a real symlink. Expected outside-scope local.
- `pnpm-registry`, `pnpm-alias`, `pnpm-tarball`: pnpm lock 9.0/layout 5/isolated manager-produced instances.
- `pnpm-peer`: real @types/react-dom 19.0.4 / @types/react 19.0.12 peer snapshot; installed instance suffix preserves peers.
- `pnpm-hashedpeer`: same dependencies with peers-suffix-max-length=1; actual lock suffix is `jc3r24zgonp253s3uzs32xbkcu`.
- `pnpm-workspace`: link to local `packages/local`.
- `pnpm-injected`: actual copied/injected workspace package. `dedupe-injected-deps=false` prevents pnpm 9 from optimizing matching peer contexts back into an ordinary link. Lock ref is `file:packages/local(ansi-regex@6.1.0)`; .modules.yaml has the injectedDeps mapping.
- `pnpm-file`: copied outside directory source, expected local; target remains inside root.
- `pnpm-path`: real link to `../outside-local`, expected outside-scope local. An ansi-regex dependency ensures pnpm emits .modules.yaml; pnpm emits no .modules.yaml for an all-link-only install.
- `pnpm-moved`: registry package in sibling `pnpm-moved-store`; .modules.yaml records `virtualStoreDir: ../../pnpm-moved-store`, relative to node_modules. Expected external even though physical target is outside fixture root.

Keep `outside-local` and `pnpm-moved-store` as siblings when relocating fixtures. Preserve symlinks. Every referenced package/root exists, and all retained symlinks were checked. The .modules.yaml content is manager-generated and retains its preparation-time storeDir and prunedAt; storeDir is the content-addressed store, not the virtual-store instance mapping.

## Verification and provenance

`verify-prepared.mjs` uses the verified local yaml 2.8.1 parser and only filesystem reads plus writing its evidence manifest. It does not spawn subprocesses, fetch, install, or execute package code. It checks 20 expected layouts, aliases and local mappings, validates versions and .d.ts existence, validates layout/lock versions and peer suffixes, and hashes retained files while checking every symlink. This verifies preparation; it is not a claim that Archway's classifier passes.

`evidence/prepared-manifest.json` lists exact targets, refs, expected dispositions, file SHA256s and link texts. `evidence/dependency-provenance.json` records official registry URLs, independently recomputed tarball SRI/SHA256 and licenses for all third-party fixture dependencies.

The verified YAML dependency to bundle is `tools/yaml-2.8.1/package` (ISC); keep its LICENSE. Official URL: https://registry.npmjs.org/yaml/-/yaml-2.8.1.tgz. Integrity: sha512-lcYcMxX2PO9XMGvAJkJ3OsNMw+/7FKes7/hgerGUYWIoWu5j/+YQqcZr5JnPZWzOsEBgMbSbiSTn/dv/69Mkpw==. SHA256: 195759b97d3f2e6085474549c069397ad7af6160be6d7c87442b8c47cb724063.

The preparation scripts download pnpm 9.15.9 into `tools/pnpm-9.15.9/package`,
with MIT LICENSE; that preparation tool is not included in the base archive. Official URL: https://registry.npmjs.org/pnpm/-/pnpm-9.15.9.tgz. Integrity: sha512-aARhQYk8ZvrQHAeSMRKOmvuJ74fiaR1p5NQO7iKJiClf1GghgbrlW1hBjDolO95lpQXsfF+UA+zlzDzTfc8lMQ==. SHA256: cf86a7ad764406395d4286a6d09d730711720acc6d93e9dce9ac7ac4dc4a28a7. pnpm is only needed during preparation, never during fixture assertions.

## Maintainer-only preparation

`prepare-fixtures.py` prepares npm fixtures and downloads/verifies/extracts official pnpm and yaml tarballs. `prepare-pnpm.py` prepares pnpm fixtures; `verify-dependency-tarballs.py` downloads/verifies dependency tarballs. `prepare-additional.py` prepares the Node ambient and pinned-Git cases and verifies their dependency tarballs. These four scripts use network and must never be called by check/test code. Preserved lockfiles pin installed instances. The archived scripts retain machine-specific Node paths. For regeneration, copy
them into disposable working directories and adapt `NODE_BIN` to a local Node
24.21.0/npm 11.19.0 installation before running them. In the base preparation
directory, run `mkdir -p downloads`; the archived script uses it as a working
directory but the base archive does not include it. Keep the supplied lockfiles
and review every changed transitive pin; the scripts are preparation recipes,
not a guarantee of byte-identical archives. The official npm registry resolved @types/react's csstype dependency to 3.2.3 at preparation time.

Create missing-lock, conflicting alias/version, metadata-mutation and conflicting
shrinkwrap/package-lock cases by modifying copies of these snapshots in isolated
tests. Keep the original package-manager output unchanged.

Pinned Git evidence: `evidence/ansi-regex-git-tag.txt` records the official annotated v6.1.0 tag resolving to f338e1814144efb950276aac84135ff86b72dc8e, matching npm registry gitHead and the installed lock.

Base preparation order: prepare-fixtures.py, prepare-pnpm.py, verify-dependency-tarballs.py, prepare-additional.py, then the offline verify-prepared.mjs. Preserve committed archives as immutable evidence; regenerate only in a separate working tree.
