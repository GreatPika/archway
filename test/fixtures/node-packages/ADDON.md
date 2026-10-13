# Additional pnpm provenance fixtures

Prepared with Node 24.21.0 and official pnpm 9.15.9, `--ignore-scripts --ignore-pnpmfile`. The base `prepared.tar.gz` (archived as `prepared-fixtures-v2.tar.gz`) remains unchanged with SHA256 9792e5f10186984f175c8720480ed361dfdab8e611bee9f1f7195e1b183ad2bd.

- `pnpm-root-override`: package.json dependency is hosted-looking `archway-outside-types: 1.0.0`, while root `pnpm.overrides` selects `file:../outside-local`. The actual generated lock records the override and sets the importer specifier and version to `file:../outside-local`. The package resolution has `directory: ../outside-local, type: directory`; actual installed instance is a virtual-store copy inside root. Expected local. Keep sibling `outside-local` to validate the source manifest and origin join.
- `pnpm-git`: root requests `git+https://github.com/chalk/ansi-regex.git#f338e1814144efb950276aac84135ff86b72dc8e`. Real pnpm 9.15.9 converts that GitHub source into `https://codeload.github.com/chalk/ansi-regex/tar.gz/f338e1814144efb950276aac84135ff86b72dc8e` importer ref and tarball resolution. Manifest is ansi-regex 6.1.0, MIT. The fixture records pnpm's Git-origin normalization.
- `pnpm-parent-snapshot`: copy of the base `pnpm-peer` fixture, without another install. Actual `@types/react@19.0.12/index.d.ts` imports `csstype`, which is absent from root importer dependencies. The parent snapshot's dependency ref is 3.2.3, and the actual sibling dependency symlink resolves to csstype@3.2.3. See evidence/parent-snapshot.json for exact paths.
- `pnpm-hashedfilename`: actual pnpm install with `virtual-store-dir-max-length=40`. Peer snapshot identity remains `@types/react-dom@19.0.4(@types/react@19.0.12)`, but installed filename is `@types+react-_nhpha4umwzujnj5z3psgctlogi`. This exercises filename truncation/hash independently of lockfile peer-suffix hashing.

All full package files, declarations and original licenses are retained. All lockfiles and .modules.yaml files are package-manager output. `prepare-addon.py` is maintainer-only and performs network/install work; never invoke it from checks. For regeneration, put the add-on working directory under the base preparation
directory. It expects the verified pnpm tool and original `pnpm-peer` fixture in
that parent directory. Adapt its archived `NODE` path to your local Node 24.21.0
installation; see [base preparation](PREPARATION.md#maintainer-only-preparation). `verify-addon.mjs` is offline and uses the included verified ISC-licensed yaml 2.8.1 package. It does not install, spawn subprocesses, fetch, or execute fixture code.

The archive writes every regular file as its own data member, even when installed files share filesystem inodes. It preserves symlinks but contains no tar hardlink records, so package subtrees can be selected for extraction without cross-member hardlink failures. Keep whole node_modules subtrees to preserve the symlink layout.

Official Git provenance is in evidence/ansi-regex-git-source.json and evidence/ansi-regex-git-tag.txt. Independent official codeload artifact SHA256: ec3037399a26c5f3cf3b88590c0185c27fc681d89271bffcfec340ef99b9c59d. Its computed SRI is sha512-DD7fxRoXRiS0djRdz/l75oy3RjoiFVMkjv3bwCg9jF62HYZ/CZhfgnKjalP3f5KLK3gLhaNO6q2Q2jEv2D7ftQ==. This checksum is additional preparation evidence; pnpm's actual lock records the URL without integrity. Registry package tarballs, exact integrity values, SHA256s and MIT licenses are recorded in evidence/dependency-provenance.json.

The committed `addon.tar.gz` SHA256 is
`5b4c7d96b6db597dc59b449ca7d826d60271bc23e831b7caa94c6b68bc55eda9`.
It includes `verify-addon.mjs`, YAML, preparation scripts and `evidence/`.
From the repository root, with Node 24.21.0 on PATH, verify a separate disposable
extraction offline:

    addon="$(mktemp -d)"
    tar -xzf test/fixtures/node-packages/addon.tar.gz -C "$addon"
    node "$addon/verify-addon.mjs"

The verifier writes `evidence/addon-manifest.json` under the extraction directory.
It verifies the fixture layout and provenance, not Archway classifier acceptance.
