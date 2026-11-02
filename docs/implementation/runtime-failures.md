# Runtime failures and cancellation

`Inspection.check(RepositorySelection)` owns the report. Its optional test
launcher substitutes only the operating-system process boundary. Production uses
an absolute verified external Dart executable, argv without a shell, an external
working directory and a sanitized environment. No project wrapper or plugin runs.

The invocation-scoped process runner owns the Dart SDK version preflight: five
seconds and 64 KiB combined raw output. Exceeding the limit, nonzero exit,
missing/wrong SDK or cancellation produces explicit incomplete evidence.
Failure/cancellation gets a two-second cleanup window. A rejected spawn has no
child; an unconfirmed spawn/exit emits RUNTIME_CLEANUP_UNCONFIRMED and blocks later
runtime launches. A late child receives best-effort kill/reap. No process-tree or
universal OS cleanup guarantee is claimed.

The executable owns and releases its SIGINT subscription. Cancellation during
synchronous analyzer work is not instantaneous. Independently verified facts and
violations remain in incomplete reports. Invalid policy prevents runtime launch.
After cleanup and output flush the entrypoint exits with its result code; this
prevents an unconfirmed child handle keeping the CLI VM alive, but does not itself
prove child termination. Broken streams/forced termination can prevent delivery.

Run `dart test test/runtime_failure_test.dart` for deterministic OS-boundary faults
and the retained process suites for actual exit/EOF/cancellation behavior. Preserve
real subprocess tests and no-project-code tripwires when changing the runner.
Original TS-helper transport limits are not a supported interface in this branch.

Record actual host, commands, passes and skips. Socket/trace restrictions and
unrun macOS/Windows cases are gaps, not successful acceptance. Inspection performs
no dependency download/preparation, generation or project execution; a claimed
syscall/network trace must actually have completed.
