import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/pub_stage_transport.dart';
import 'support/pub_candidate_fixture.dart';
import 'support/pub_native_fixture.dart';

void main() {
  test(
    'installed pub admission binds descriptor before SDK activation',
    () async {
      final fixture = await preparePubCandidateFixture();
      addTearDown(() => fixture.fixture.root.deleteSync(recursive: true));
      final source = fixture.fixture.source;
      final identity = fixture.fixture.identity;
      final transport = Directory(
        p.join(fixture.fixture.root.path, 'transport'),
      );
      final record = await writePubTransport(
        fixture.candidate,
        source,
        transport,
        identity['commit'] as String,
        '123',
        '2',
        registryReady: true,
      );
      final descriptor = fixture.fixture.descriptor;
      final original = descriptor.readAsStringSync();
      final changed = jsonDecode(original) as Map;
      changed['version'] = '0.2.1';
      descriptor.writeAsStringSync(jsonEncode(changed));
      final target = switch (Abi.current()) {
        Abi.linuxX64 => 'linux-x64',
        Abi.macosArm64 => 'macos-arm64',
        Abi.windowsX64 => 'windows-x64',
        _ => throw UnsupportedError('Unsupported test host'),
      };
      final output = Directory(p.join(fixture.fixture.root.path, 'installed'));
      final native = File(p.join(fixture.fixture.root.path, 'native.tar.gz'))
        ..writeAsStringSync('untrusted bytes');
      Future<ProcessResult> invoke({bool registry = true}) =>
          Process.run(Platform.resolvedExecutable, [
            'run',
            'tool/ci/pub_installed_route.dart',
            if (registry) '--registry-ready',
            '--source',
            source.path,
            '--expected-source',
            identity['commit'] as String,
            '--run-id',
            '123',
            '--run-attempt',
            '2',
            '--target',
            target,
            '--transport',
            p.join(transport.path, 'installation.tar'),
            '--expected-json',
            jsonEncode(record),
            '--descriptor',
            descriptor.path,
            '--wrong-node',
            Platform.environment['ARCHWAY_TEST_WRONG_NODE'] ??
                'unused-wrong-node',
            '--native-archive',
            native.path,
            '--prepared-cache',
            Platform.environment['PUB_CACHE']!,
            '--output',
            output.path,
          ]);
      final privateIntent = await invoke(registry: false);
      expect(privateIntent.exitCode, 1);
      expect(
        privateIntent.stderr,
        contains('schema or explicit registry intent differs'),
      );
      expect(
        Directory(p.join(output.path, 'activation')).existsSync(),
        isFalse,
      );
      output.deleteSync(recursive: true);
      final mismatched = await invoke();
      expect(mismatched.exitCode, 1);
      expect(
        mismatched.stderr,
        contains('Installed descriptor differs from stage'),
      );
      expect(
        Directory(p.join(output.path, 'activation')).existsSync(),
        isFalse,
      );
      expect(File(p.join(output.path, 'report.json')).existsSync(), isFalse);
      descriptor.writeAsStringSync(original);
      output.deleteSync(recursive: true);
      final badNative = await invoke();
      expect(badNative.exitCode, 1);
      expect(
        badNative.stderr,
        contains('Archive input differs from pinned identity'),
      );
      expect(
        Directory(p.join(output.path, 'activation')).existsSync(),
        isFalse,
      );
      expect(File(p.join(output.path, 'report.json')).existsSync(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('failed activation allocation releases the private registry listener', () async {
    late File native;
    final target = switch (Abi.current()) {
      Abi.linuxX64 => 'linux-x64',
      Abi.macosArm64 => 'macos-arm64',
      Abi.windowsX64 => 'windows-x64',
      _ => throw UnsupportedError('Unsupported test host'),
    };
    final fixture = await preparePubCandidateFixture(
      beforeStage: (fixture) async {
        native = preparePubNativeFixture(fixture);
      },
    );
    addTearDown(() => fixture.fixture.root.deleteSync(recursive: true));
    final transport = Directory(p.join(fixture.fixture.root.path, 'transport'));
    final record = await writePubTransport(
      fixture.candidate,
      fixture.fixture.source,
      transport,
      fixture.fixture.identity['commit'] as String,
      '123',
      '2',
      registryReady: true,
    );
    final output = Directory(p.join(fixture.fixture.root.path, 'installed'));
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      'tool/ci/pub_installed_route.dart',
      '--registry-ready',
      '--source',
      fixture.fixture.source.path,
      '--expected-source',
      fixture.fixture.identity['commit'] as String,
      '--run-id',
      '123',
      '--run-attempt',
      '2',
      '--target',
      target,
      '--transport',
      p.join(transport.path, 'installation.tar'),
      '--expected-json',
      jsonEncode(record),
      '--descriptor',
      fixture.fixture.descriptor.path,
      '--wrong-node',
      Platform.environment['ARCHWAY_TEST_WRONG_NODE'] ?? 'unused-wrong-node',
      '--native-archive',
      native.path,
      '--prepared-cache',
      Platform.environment['PUB_CACHE']!,
      '--output',
      output.path,
    ]);
    final stdout = process.stdout.transform(utf8.decoder).join();
    final stderr = process.stderr.transform(utf8.decoder).join();
    final exit = process.exitCode;
    try {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (!output.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(output.existsSync(), isTrue);
      // The exclusively owned evidence root is observed before slow admission.
      File(p.join(output.path, 'activation'))
          .writeAsStringSync('allocation conflict');
      final code = await exit.timeout(
        const Duration(seconds: 10),
        onTimeout: () => -999,
      );
      if (code == -999) {
        process.kill(ProcessSignal.sigkill);
        await exit;
      }
      expect(await stderr, contains('activation'));
      expect(
        code,
        1,
        reason: 'Failed acceptance must terminate without a live listener',
      );
      expect(await stdout, isEmpty);
      expect(File(p.join(output.path, 'report.json')).existsSync(), isFalse);
    } finally {
      process.kill(ProcessSignal.sigkill);
      await exit;
      await stdout;
      await stderr;
    }
  }, timeout: const Timeout(Duration(minutes: 2)));
}
