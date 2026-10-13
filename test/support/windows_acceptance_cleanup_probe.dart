// Host-neutral probe of the same Windows ownership/failure boundary. No native
// handles or processes are injected; stdout/stderr distinguish parent diagnostics.
import 'dart:async';
import 'dart:io';

import '../../tool/ci/native_acceptance_capture.dart';

Future<void> main(List<String> arguments) async {
  final root = arguments.single;
  final primary = TimeoutException('original deadline');
  try {
    await captureWithWindowsOwners(
      capture: () async {
        File('$root${Platform.pathSeparator}child.stdout')
            .writeAsBytesSync([0, 255, 1]);
        File('$root${Platform.pathSeparator}child.stderr')
            .writeAsBytesSync([254, 2, 0]);
        throw primary;
      },
      closeJob: () => throw StateError('injected job cleanup failure'),
      closeChild: () {},
      closePipes: () {},
    );
    throw StateError('Capture unexpectedly succeeded');
  } catch (error) {
    if (!identical(error, primary)) rethrow;
    stdout.write('original timeout retained');
    await Future.wait([stdout.flush(), stderr.flush()]);
  }
}
