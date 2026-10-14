# Runtime failures and cancellation

## Ownership and fixed budgets

`Inspection.check(RepositorySelection)` owns the complete report. Its
optional constructor launcher substitutes only the operating-system process
boundary for deterministic rare-failure tests. Default execution always uses
an absolute pinned executable, argv without a shell, an external working
directory, and a sanitized environment. There are no deadline overrides or
project-provided helper paths.

One invocation-scoped runner covers Node and Dart preflights and TypeScript
helpers. Each preflight has a five-second deadline and a 64 KiB combined raw-output
limit. Each TypeScript helper invocation has 120 seconds from spawn through stdin
completion, successful exit and both output EOFs. Request/stdout/stderr limits are
8 MiB/64 MiB/256 KiB. Equality is allowed;
the first byte over invalidates that project's entire envelope. Success checks
monotonic elapsed time as well as the timer. All asynchronous failures are
observed as they occur, rather than waiting for process exit first.

Failure/cancellation gets one additional two-second cleanup window. A confirmed
spawn rejection has no child to reap. A pending spawn or unconfirmed exit at the
end of cleanup adds `RUNTIME_CLEANUP_UNCONFIRMED` and blocks all later runtime or
helper launches in that check, including the other language. A late arriving
process receives an error-observing best-effort kill/reap attempt. A confirmed
direct-child exit is termination evidence even if kill refused/threw or local
stream disposal stalled. No process-tree or universal OS cleanup guarantee is
made. Buffered response data is released on completion/failure.

The executable owns a SIGINT subscription and releases it in `finally`. CLI and
Inspection constructors merely accept the cancellation future; `run` and
`check` signatures are unchanged, and non-check commands never query runtimes.
Cancellation during synchronous analyzer work is not instantaneous. Cancellation
makes the final check incomplete while retaining already validated independent
facts and violations. Invalid policy still prevents any runtime launch. After signal cleanup and
awaiting stdout/stderr flush, the standalone entrypoint explicitly exits with
the returned code. This prevents an unconfirmed native child handle from keeping
the CLI VM alive. Explicit parent exit does **not** terminate/reap an unconfirmed
child; output flush confirms acceptance by the underlying consumer, not receipt
by an external observer. Broken/hostile output streams remain outside guaranteed
delivery. See Dart [exit](https://api.dart.dev/dart-io/exit.html) and
[IOSink.flush](https://api.dart.dev/dart-io/IOSink/flush.html).

## Tests and reproduction

For the Linux process checks below, use the pinned Dart 3.13.3 SDK with
`--suppress-analytics` for every Dart command,
Node 24.21.0, prepared dependencies/assets, and the repository
native bridge build. DART/NODE are absolute executables, DART_SDK is the SDK root,
and WRONG_NODE is a real incompatible Node executable (the fixture uses 24.19.0).
Run from repository root with these pinned runtime directories on PATH and a
fresh build/install destination:

```sh
sh tool/build_native.sh
"$DART" --suppress-analytics test
"$DART" --suppress-analytics analyze
sh tool/assemble.sh
"$DART" --suppress-analytics test test/runtime_capture_test.dart
dart --suppress-analytics run test/check_process_smoke.dart build/install/bin/linux-x64/archway "$NODE"
dart --suppress-analytics run test/runtime_process_smoke.dart build/install/bin/linux-x64/archway "$NODE"
dart --suppress-analytics run test/runtime_request_process_smoke.dart build/install/bin/linux-x64/archway "$NODE"
dart --suppress-analytics run test/runtime_preflight_process_smoke.dart build/install/bin/linux-x64/archway "$NODE" "$WRONG_NODE" "$DART_SDK"
```

`runtime_process_smoke.dart` uses the 120-second production deadline;
it has no accelerated-clock mode. Every process suite validates one complete
public JSON line, actual exit status, and silent stderr. The standalone fixtures
copy installed assets with symlinks preserved, so an installation-safety failure
cannot be hidden by dereferencing assets during setup.

- A real entrypoint harness demonstrates bounded parent exit despite a pending
  native child handle; its Linux outer harness kills/reaps the fixture child.
- Real processes cover SIGINT + confirmed reap, EOF/exit ordering, late output
  after parent exit, exact/+1 stdout/stderr/request limits, the five-second
  preflight deadline, combined preflight limit, nonzero exit, and runtime lookup.
- A real Node 24.19.0 binary is rejected; repository/cwd/relative PATH entries and
  aliases to repository runtimes never execute their marker payloads.
- Installed compiler mismatch/load failure/missing assets leave its public
  version null and retain independently verified Dart facts and violations.
- Envelope checks reject truncated/multiple/invalid UTF-8/BOM frames,
  escaped duplicate nested keys, unknown fields, mismatched request/project,
  wrong ordering, duplicate provenance IDs and inconsistent statuses. A valid
  failed response still retains verified facts and architectural violations.
- `runtime_failure_test.dart` injects only OS-boundary failures through
  `Inspection.check`: refused/thrown kill, unreaped exit, pending/late spawn,
  pipe and stdin failures, cross-language launch blocking, and cancellation.
  These deterministic tests supplement actual lifecycle execution.

## Evidence and remaining gates

These process fixtures exercise Linux x64 development-host cases. Socket cases
may explicitly skip when binding is prohibited. Results do not establish macOS
or Windows acceptance. Inspection does not download, install, build projects or
execute project source, package scripts, compiler plugins or environment preloads.
Execution tripwires check those boundaries; syscall-level network assertions
require a successful trace for the claimed route and host. A denied or skipped
trace is not proof. See the [installation guide](installation-layout.md) for
asset trust and layout.
