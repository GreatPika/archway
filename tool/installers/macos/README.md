# macOS unsigned preview installer

This tool builds a conventional component `.pkg` for the macOS 15 arm64 preview.
It is **unsigned and unnotarized**. Downloaded files may require a separate user
trust decision or be blocked by macOS. A checksum verifies bytes, not publisher
identity. Do not disable security, remove quarantine, change trust settings or
use borrowed signing identities. Native build and lifecycle evidence do not
certify the downloaded-file GUI experience.

## Build (maintainer only)

Pass the unpacked macOS release bundle produced by `tool/release_bundles.py`,
including its original manifest, assets, schemas, notices and guide. The caller
must verify source/transport provenance before this step; the builder rechecks
its complete file inventory and copies payload bytes/modes unchanged. Fresh
outputs must remain outside the input bundle, including through parent aliases. Installer
ownership metadata and `uninstall.sh` are separate from that original manifest.
Do not pass the bare assembly directory or fabricate missing assets.

```sh
python3 tool/installers/macos/build.py --bundle /absolute/verified-bundle --output /absolute/fresh-output
```

Native builds require macOS arm64 and Apple's `/usr/bin/pkgbuild`; Python is only
a maintainer build prerequisite. The resulting installer requires no Python,
Node, Dart, compiler, download or project preparation. `--stage-only` permits
synthetic/Linux packaging tests; it does not produce a `.pkg` or acceptance proof.
The build writes `installer-evidence.json` with original source identity,
manifest hash, build host and final unsigned package hash. Shared release wiring
and exact-source acceptance remain separate.

## Installation and ownership

Open the `.pkg` through the ordinary macOS Installer experience. Installation
requires administrator authorization and targets the running system volume only:

- Complete private layout: `/usr/local/lib/archway`
- Command: `/usr/local/bin/archway`, an owned symlink to the native executable
- Package receipt: `org.archway.cli`
- Added ownership record: `.archway-owned.sha256` (SHA-256, octal mode, path)

No shell profile or PATH is edited. Test command discovery in a newly opened
standard terminal; `/usr/local/bin` is expected on its normal PATH. An existing
foreign root or command, aliased parent, modified/missing owned file or incoming
file collision causes preflight refusal before installation mutation. Upgrade
requires both the native receipt and inventory. Unchanged obsolete owned files
are removed after extraction; foreign files are preserved. This detects ordinary
ownership conflicts, not hostile concurrent root modifications.

Upgrades and cancellation use standard macOS Installer behavior. There is no
promise of complete rollback for interruption, disk failure or script failure.
Cancelling before extraction leaves the installation untouched. A partial
extraction may require administrator recovery; keep the previous installer and
inspect the native Installer log. Do not repeatedly force an ownership conflict
or recursively delete the root. Postinstall checks copied payload hashes before
recording ownership and registering the command.

## Explicit uninstall

```sh
sudo /bin/sh /usr/local/lib/archway/uninstall.sh
```

The uninstaller requires the receipt, validates the owned-file inventory and
checks aliases before deletion. It removes only inventoried files with unchanged bytes and permission bits,
the exact owned command symlink and emptied inventoried directories, then
forgets the receipt. Modified files, unknown files, replaced commands, projects
and unrelated settings remain. A nonempty root is reported and preserved; move
those remaining personal files deliberately before attempting a fresh install.
Never use recursive mixed-root removal. If receipt removal fails, the script
reports failure; there is no full-transaction rollback promise.

## Verification still required

`python3 -m unittest discover -s test -p macos_installer_test.py` exercises
synthetic payloads and staged lifecycle scripts in isolated filesystem fixtures.
On Linux these tests substitute the host check, receipt lookup and BSD stat's
mode-field query with GNU stat, and simulate
package extraction. They are not native macOS package-manager evidence.

On actual updated macOS 15 arm64, retain the final `.pkg` SHA-256 and verify:
clean install, fresh-terminal `command -v archway`, installed process fixtures
from another cwd with spaces/Unicode, init and runtime-free policy/query/export,
prepared checks and missing/wrong runtimes, owned upgrade, foreign collisions,
cancellation/failure behavior and uninstall with foreign files in the root.
Reuse existing native/check process fixtures; record their prerequisites and
outputs. Separately download those exact final bytes through the intended public
route and record GUI trust prompts/user decisions. No such target-host or GUI
acceptance is claimed by this implementation's Linux tests.
