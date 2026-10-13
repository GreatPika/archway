import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'check_process_smoke.dart' show captureCheckHelper;
import 'support/native_process_support.dart';

void main() {
  test('direct capture forwards raw bytes and nonzero status', () async {
    final node = Platform.environment['ARCHWAY_TEST_NODE']!;
    final base = Directory.systemTemp.createTempSync('archway-capture-bytes-');
    try {
      final helper = File(p.join(base.path, 'helper.cjs'))
        ..writeAsStringSync(
          "process.stdin.on('data',b=>process.stdout.write(b));process.stdin.on('end',()=>{process.stdout.write(Buffer.from([255]));process.stderr.write(Buffer.from([254]));process.exitCode=7;});",
        );
      final result = await captureCheckHelper(
        node,
        helper.path,
        'request café',
      );
      expect(result.exitCode, 7);
      expect(result.stdout, [...utf8.encode('request café'), 255]);
      expect(result.stderr, [254]);
    } finally {
      base.deleteSync(recursive: true);
    }
  });
  test('hanging helper is forcibly killed and reaped before wrapper returns', () async {
    final node = Platform.environment['ARCHWAY_TEST_NODE']!;
    final base = Directory.systemTemp.createTempSync('archway-capture-hang-');
    final pid = File(p.join(base.path, 'pid'));
    var reaped = false;
    try {
      final helper = File(p.join(base.path, 'helper.cjs'))
        ..writeAsStringSync(
          "require('node:fs').writeFileSync(${jsonEncode(pid.path)},String(process.pid));process.on('SIGTERM',()=>{});setInterval(()=>{},1000);",
        );
      final result = await captureCheckHelper(node, helper.path, '{}');
      expect(result.exitCode, isNot(0));
      expect(utf8.decode(result.stderr), contains('ETIMEDOUT'));
      expect(pid.existsSync(), isTrue);
      final childPid = int.parse(pid.readAsStringSync());
      final probe = await runNativeProcess([
        node,
        '-e',
        "try{process.kill($childPid,0);throw Error('Helper remains alive');}catch(e){if(e.code!=='ESRCH')throw e;}",
      ], timeout: const Duration(seconds: 5));
      expect(probe.exitCode, 0, reason: utf8.decode(probe.stderr));
      reaped = true;
    } finally {
      // Also clean up when this regression fails against a broken wrapper.
      if (!reaped && pid.existsSync()) {
        Process.killPid(
          int.parse(pid.readAsStringSync()),
          ProcessSignal.sigkill,
        );
      }
      base.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 25)));
}
