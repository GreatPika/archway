# Ubuntu package installer

Build an unsigned .deb from a complete extracted Linux release bundle:

```sh
dart run tool/installers/linux/build.dart \
  --bundle /absolute/extracted-bundle \
  --expected-commit FULL_PAYLOAD_SOURCE_COMMIT \
  --output /absolute/fresh/archway.deb
```

This build-time tool needs Dart and dpkg-deb. Installation needs only
standard OS/package-manager tools, not Node or Dart. The existing bundle
manifest supplies version, source and byte/mode inventory. Input, copied stage
and final .deb readback must agree. The build preserves payload bytes and emits
the final .deb SHA-256; checksums do not authenticate a publisher.

The package owns `/usr/lib/archway` and `/usr/bin/archway`. Preflight rejects
unowned installation roots, foreign command registrations and collisions with
new payload paths. dpkg owns upgrades, stale-file removal and uninstall; there
is no custom transaction engine, rollback promise, recursive root removal,
PATH editing, runtime download or project preparation. Project files and extra
unowned files are left alone. Administrative authentication is normal for this
system package. Use the desktop package manager's removal action to uninstall.

`dart test test/linux_installer_builder_test.dart` builds real .deb files from synthetic
release fixtures. Lifecycle tests run actual dpkg in an unprivileged user
namespace against a temporary filesystem and package database. They never
install Archway into the host or change its security settings. User namespaces
must already be permitted; do not enable them by changing system policy.
These tests prove packaging/ownership behavior, not execution of the real native
CLI, standard fresh-terminal discovery, or Ubuntu Desktop GUI acceptance.

Remaining acceptance: the exact final payload's installed-process suites and
actual downloaded-file GUI install on updated Ubuntu 24.04 Desktop x64, followed
by a fresh standard terminal, upgrade and uninstall. Analysis runtime/compiler
pins and prepared-project prerequisites remain unchanged. No package is
published by this tool and no public installation claim follows from fixtures.
