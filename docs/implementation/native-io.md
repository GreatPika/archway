# Native I/O and physical paths

Use this guide for bridge ownership, filesystem identity and mutation safety.
The private [ABI header](../../native/io.h) is authoritative for wire declarations;
[NativeIo](../../lib/src/native/native_io.dart) owns binding/version checks,
captured errors and matched allocation. Backends exist for Linux x64/glibc,
macOS arm64 and Windows x64. Implemented routes do not establish platform
certification; see [CI scope](../../tool/ci/README.md).

## ABI and resource ownership

ABI 2 carries a 16-byte value/native-error/status result. Status combines a
category and native domain (none, POSIX, Win32 or NTSTATUS). Successful handle
zero is valid; failures transfer no handle. Native errors are captured before
cleanup/FFI return. Synthetic validation has no native error. Conflict decisions
use categories rather than assumed POSIX numbers.

The bridge owns directory handles, output creation, entry observation,
write/flush/close, raw aliases and allocation. OS flags and root sentinels remain
inside the backend. Close consumes ownership even on error and is never retried.
Short writes advance by the returned count; only interrupted writes retry.
Allocations are freed by the same loaded bridge in finally blocks.

Linux/macOS open outputs nonblocking/nofollow, validate the opened regular file
before same-handle truncation/write, and observe entries without following links.
Windows validates ordinary non-reparse handles before truncation and uses
handle-relative child operations. Exclusive create stays exclusive; ordinary
hardlink overwrite semantics remain. These checks do not provide an atomic
filesystem snapshot or safety against arbitrary hostile concurrent replacement.

Alias reads preserve raw targets and strict encoding (including a UTF-8 BOM).
Buffers double from 256 bytes through 1 MiB; capacity-equal results are rejected
conservatively. Windows supports relative and local NT-drive symlinks/junctions;
other absolute forms remain fail-closed. Ordinary operations needing no alias or
native output can avoid loading the bridge; required missing assets fail closed.

## Physical observations

- Excluded subtrees are skipped before following scope prefixes. Included source
  links are refused; undiscovered linked corpus cannot report clean.
- POSIX backslashes remain literal until portability validation. NFC/case
  ambiguity cannot choose an owner. Case-sensitive names and hardlinks remain
  distinct; target-native case probes are guarded, not blanket lowercasing.
- Unrepresentable/missing or duplicate decoded inventory names fail before
  traversal. Genuine U+FFFD names remain valid; invalid-byte collisions do not.
- Ordered raw link-hop witnesses are captured before canonicalization, including
  intermediate/external hops and routes to absent child probes. Dot segments
  follow filesystem-order expansion.
- Shared-route witnesses are compared separately from canonical content identity.
  Conflicting baselines invalidate supplying projects' discovery/facts; stable
  distinct routes to the same target are allowed.
- Every observation is independently rechecked even after an unreadable alias.
  Same-final-target route changes are detected; established independent violations
  survive under the changed-input contract. Rechecks cover an observation window,
  not a transaction.

Dart resource reads reject nonregular objects before synchronous opening, avoiding
stable FIFO hangs. TypeScript's private exchange carries ordered witnesses for
positive and absent inputs. Physical containment or node_modules spelling alone
never proves external package origin; use the [Dart](dart-check.md) and
[TypeScript](typescript-packages.md) origin guides.

## Reproduction and interpretation

Run from repository root with pinned Dart/Node and prepared assets. Build the
host bridge with tool/build_native.sh (Linux), tool/build_native_macos.sh (macOS)
or tool/build_native_windows.ps1 (Windows). See [assembly](installation-layout.md).
The following process suites are Linux checks; EXE is the absolute assembled
bin/linux-x64/archway path, DART_SDK is the SDK root and NODE is the absolute pinned
Node executable:

```sh
sh tool/build_native.sh
dart --suppress-analytics analyze
dart --suppress-analytics test --concurrency=2
sh tool/assemble.sh build/install
dart --suppress-analytics run test/native_abi_process_smoke.dart "$EXE"
dart --suppress-analytics run test/native_fault_process_smoke.dart "$EXE"
dart --suppress-analytics run test/native_asset_process_smoke.dart "$EXE"
dart --suppress-analytics run test/catalogue_export_process_smoke.dart "$EXE"
dart --suppress-analytics run test/physical_path_process_smoke.dart "$EXE" "$DART_SDK" "$NODE"
dart --suppress-analytics run test/alias_wire_process_smoke.dart "$EXE" "$NODE"
dart --suppress-analytics run test/dart_resource_process_smoke.dart "$EXE" "$DART_SDK"
```

The independent ABI fixture checks compiled CLI decoding; its Win32/NTSTATUS
values are not Windows ABI evidence. Linux syscall fault substitution verifies
outcomes, byte preservation and exact close attempts without production switches.
Process cases include invalid UTF-8/long aliases, malformed hop evidence, cycles,
missing bridges and route mutation. Dart tests supplement them with BOM/dangling
aliases, FIFO, hardlink and resource-type cases. Full regression environments need
prepared Git/Flutter fixtures from the Dart guide.

Linux host results do not establish macOS normalization, Windows reparse/case
behavior, Windows 11 acceptance, clean target OS acceptance or installation-route
acceptance. Functional execution tripwires do not replace a successful syscall
trace.
