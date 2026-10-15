// SDK snapshot controls shared by private installed acceptance and its IO fixture.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../test/support/native_process_support.dart';
import '../release/archive_input.dart';
import '../validation/json_values.dart';
import 'release_execution_receipts.dart';

Future<Map<String, Object?>> exercisePubSnapshots({
  required Directory pubCache,
  required Directory wrapper,
  required Future<NativeProcessResult> Function() invoke,
  int expectedExit = 0,
}) async {
  void require(bool value, String message) {
    if (!value) throw StateError(message);
  }

  final source = File(p.join(wrapper.path, 'bin', 'archway.dart'));
  final snapshot = File(
    p.join(
      pubCache.path,
      'global_packages',
      'archway',
      'bin',
      'archway.dart-${Platform.version.split(' ').first}.snapshot',
    ),
  );
  final sourceBytes = readOrdinaryBytes(source);
  final snapshotBytes = readOrdinaryBytes(snapshot, limit: maxArchiveBytes);
  final baseline = await invoke();
  require(baseline.exitCode == expectedExit, 'Snapshot baseline failed');
  final cases = <Map<String, Object?>>[];
  try {
    source.writeAsStringSync('deliberately invalid installed wrapper source\n');
    final poisoned = await invoke();
    require(
      poisoned.exitCode == expectedExit &&
          sameJson(poisoned.stdout, baseline.stdout) &&
          sameJson(poisoned.stderr, baseline.stderr) &&
          sameJson(snapshot.readAsBytesSync(), snapshotBytes),
      'Warm SDK snapshot changed after installed source poisoning',
    );
    cases.add({'case': 'poisoned-source-snapshot', 'exit': poisoned.exitCode});
    snapshot.writeAsStringSync('invalid snapshot bytes\n');
    final stale = await invoke();
    require(
      stale.exitCode != 0 &&
          stale.exitCode != expectedExit &&
          stale.stderr.isNotEmpty &&
          !sameJson(stale.stdout, baseline.stdout),
      'Stale SDK snapshot unexpectedly dispatched native output',
    );
    cases.add({'case': 'stale-snapshot', 'exit': stale.exitCode});
    snapshot.deleteSync();
    final missing = await invoke();
    require(
      missing.exitCode != 0 &&
          missing.exitCode != expectedExit &&
          utf8.decode(missing.stderr).contains('Error') &&
          !sameJson(missing.stdout, baseline.stdout),
      'Missing SDK snapshot unexpectedly dispatched native output',
    );
    cases.add({'case': 'missing-snapshot', 'exit': missing.exitCode});
  } finally {
    source.writeAsBytesSync(sourceBytes);
    snapshot.writeAsBytesSync(snapshotBytes);
  }
  require(
    sameJson(source.readAsBytesSync(), sourceBytes) &&
        sameJson(snapshot.readAsBytesSync(), snapshotBytes),
    'SDK snapshot control did not restore owned files',
  );
  return {
    'sdk': Platform.version.split(' ').first,
    'snapshot_sha256': sha256.convert(snapshotBytes).toString(),
    'source_sha256': sha256.convert(sourceBytes).toString(),
    'cases': cases,
  };
}
