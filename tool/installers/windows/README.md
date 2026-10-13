# Windows unsigned installer

This consumes the existing **verified Windows release bundle** (the extracted
`archway-<version>-windows-x64.zip` contents with its release `manifest.json`).
It does not assemble, download, sign, publish or certify the payload. The caller
must first verify the archive and source provenance. The
converter reuses the release inventory and manifest reader; it only emits Inno syntax
and an installed owned-file inventory. It never changes input bytes.

On a provisioned Windows x64 build host with Python and Inno Setup 6.3 or newer:

```powershell
python tool/installers/windows/prepare.py C:\verified\bundle C:\build\inno-input
& 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe' /DAppVersion=0.1.0 /DOutputDir=C:\build\unsigned C:\build\inno-input\archway.iss
```

Use fresh build/output directories. Provision the official compiler separately;
this code does not accept its license or install build tools. Record the compiler
version, source commit, actual host/CPU, payload inventory and final EXE SHA-256
in the release evidence. Unsigned checksums do not authenticate a publisher.

The installer places the complete private payload below
`%LocalAppData%\Programs\Archway`. Its stable AppId owns conventional Inno
upgrade/uninstall behavior. It refuses foreign roots/command collisions and
reparse-point destinations before copying. Existing owned trees are enumerated
without following reparse entries, including historical or unlisted paths, before
upgrade and uninstall mutations. Enumeration errors refuse the operation. This
read-only preflight does not provide an atomic snapshot against concurrent
filesystem replacement. Stale files are removed only when the
previous owned inventory/hash proves ownership, after installation. Uninstall
uses Inno's individual file log, never recursive mixed-root deletion. Files added
by users at distinct paths survive. Editing an installer-owned file does not
remove its ownership from Inno's uninstall log.

User PATH registration uses Inno's raw, dynamically sized registry string reader
and writer. `RegWriteStringValue` retains existing `REG_EXPAND_SZ`; `REG_SZ` stays
`REG_SZ`. Tokens are compared after expansion only for collision detection; the
stored value is never expanded or normalized. The exact added token is persisted
in `HKCU\Software\Archway\Installer`, survives upgrade, and is removed from the
**current** PATH at uninstall. Pre-existing equivalent tokens are not adopted.
Ambiguous duplicates fail explicitly without PATH removal. ChangesEnvironment
notifies applications; existing shells retain their old environment.

There is no custom transaction/rollback engine or crash guarantee. Cancellation
is available before copying; Inno disables cancellation while copying. Locked
files, write failures and interrupted upgrades follow native Inno behavior. PATH
updates are bounded read-modify-write operations, not an atomic registry compare
and swap; concurrent external PATH writers are not synchronized. If ownership
persistence fails after PATH registration, the installer reports an error rather
than restoring a snapshot over subsequent edits. Recovery and native failure
cases must be measured before acceptance.

## Verification

`python -m unittest discover -s test -p windows_installer_prepare_test.py` verifies
build-input behavior on any host. On an explicitly disposable Windows account:

```powershell
python test/windows_installer_lifecycle.py --installer C:\artifacts\old.exe --upgrade C:\artifacts\new.exe --stale-file obsolete/installer-probe..txt --disposable-account
```

The old installer must contain the named stale file and the upgrade must omit it;
the harness fails rather than counting an empty inventory difference as coverage.
The stale path must have a non-root parent directory for the junction
probe. The filename must contain a literal double dot within a component (as in the
example), proving the producer and native inventory reader accept ordinary names
without mistaking them for a parent-directory traversal component.
Build that transition using clearly labeled fixture bundle copies, never by
mutating previously verified transport bytes. The failure probe holds this file
open without delete-sharing, causing real stale cleanup to fail after copying.
Setup must then return exit **20**; an error dialog alone is not sufficient.
The [official event contract](https://jrsoftware.org/ishelp/topic_scriptevents.htm)
provides `GetCustomSetupExitCode` for this otherwise-successful completion case.

That harness changes the account's real PATH and installs/uninstalls real bytes.
After a successful uninstaller launcher exit it waits within the 180-second
operation deadline for the uninstaller EXE and post-uninstall ownership markers
to disappear. Inno's launcher can exit before its second phase finishes. A timeout
is fatal; exact PATH/foreign-file checks and strict empty-root removal still run.
It covers registry types, long raw strings, pre-existing tokens, upgrade ownership,
subsequent edits, payload hashes/stale files, foreign roots/commands and foreign
file preservation, duplicate-owned-token refusal, root junction refusal and the
locked stale-file failure. It also checks a child process from a spaced/Unicode cwd;
this is not a fresh desktop terminal test. Run existing installed CLI fixtures
for init/policy/query/export, prepared checks and missing/wrong runtimes separately.

Compilation and native lifecycle verification require a Windows host.
Windows 11 24H2 x64 downloaded-file GUI/trust prompts, fresh standard terminal,
cancellation, locked files and injected registry failures remain acceptance gates.
Windows Server/headless or fixture results cannot establish desktop GUI acceptance.

Official semantics: [registry writer](https://jrsoftware.org/ishelp/topic_isxfunc_regwritestringvalue.htm),
[registry reader](https://jrsoftware.org/ishelp/topic_isxfunc_regquerystringvalue.htm),
[per-user privileges](https://jrsoftware.org/ishelp/topic_setup_privilegesrequired.htm),
[installation order](https://jrsoftware.org/ishelp/topic_installorder.htm).

The release workflow invokes `run_windows` in `tool/ci/native_windows_installer_probe.py`
on the verified immutable bundle and a fresh output directory. It requires the
already-provisioned compiler at `%ProgramFiles(x86)%\Inno Setup 6\ISCC.exe`,
requires its engine self-report to identify version 6.3 or newer, and records its
hash. The preflight compiles a fixed stdin script with `/O-` and `Output=no`,
requires success, and retains the engine-version log without emitting an installer.
ISCC PE version resources can be 0.0.0.0 and its help banner only names the major
version; neither establishes the minimum. It never installs build tools. The final unsigned EXE, command logs and their hashes are retained;
the copied 0.0.0 old-generation fixture is temporary and explicitly test-only.
The shared installed-command callback runs once against the verified final
installed bytes, before uninstall. The lifecycle also replaces the obsolete
old-generation directory with an NTFS junction before uninstall and requires the
foreign target (including an old-generation filename) to survive. Both uninstall
and upgrade must refuse while preserving PATH, ownership, inventory and payload.
A nested unlisted Unicode directory with a junction receives the same checks;
ordinary empty directories remain permitted. Native execution is required to
establish these behaviors.
