import 'dart:async';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';

Future<void> main(List<String> args) async {
  final cancelled = Completer<void>();
  StreamSubscription<ProcessSignal>? interrupt;
  try {
    // SIGINT is supported by dart:io on the target systems. A restricted host
    // may refuse signal registration; that must not break ordinary commands.
    interrupt = ProcessSignal.sigint.watch().listen((_) {
      if (!cancelled.isCompleted) cancelled.complete();
    }, onError: (Object _) {});
  } on SignalException {
    // No signal-handling claim is made for a host that refuses registration.
  } on UnsupportedError {
    // Embeddings without signal support retain normal CLI operation.
  }
  final int code;
  try {
    code = await CLI(cancelled: cancelled.future)
        .run(args, CliStreams(stdout, stderr));
  } finally {
    await interrupt?.cancel();
  }
  // A native child whose reap could not be confirmed can keep the VM alive.
  // Complete local cleanup and accept buffered output before exiting the CLI.
  // This does not terminate or reap an unconfirmed child process.
  await stdout.flush();
  await stderr.flush();
  exit(code);
}
