import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/native_release_host.dart';
import 'support/native_process_support.dart';

void main() {
  test('unverified release still refuses a foreign native target', () async {
    final foreign = Abi.current() == Abi.linuxX64 ? 'macos-arm64' : 'linux-x64';
    await expectLater(
      nativeReleaseHost(foreign, ciHost: false),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          contains('Wrong native host'),
        ),
      ),
    );
  });

  test('actual host receipt retains operating system observations', () async {
    final host = await nativeReleaseHost(nativeTarget().target, ciHost: false);
    expect(
      host.keys,
      unorderedEquals(['system', 'machine', 'version', 'release']),
    );
    expect(
      host.values,
      everyElement(isA<String>().having((s) => s.isNotEmpty, 'nonempty', true)),
    );
    if (!Platform.isWindows) {
      for (final (field, flag) in [
        ('system', '-s'),
        ('machine', '-m'),
        ('version', '-v'),
        ('release', '-r'),
      ]) {
        final observed = Process.runSync('/usr/bin/uname', [flag]);
        expect(observed.exitCode, 0);
        expect(host[field], '${observed.stdout}'.trim());
      }
    }
    if (Platform.isLinux) {
      final release = File('/etc/os-release').readAsStringSync();
      final libc = Process.runSync('/usr/bin/getconf', ['GNU_LIBC_VERSION']);
      expect(libc.exitCode, 0);
      final pinned =
          RegExp(r'^ID="?ubuntu"?$', multiLine: true).hasMatch(release) &&
          RegExp(
            r'^VERSION_ID="?24\.04"?$',
            multiLine: true,
          ).hasMatch(release) &&
          '${libc.stdout}'.trim() == 'glibc 2.39';
      if (pinned) {
        expect(await nativeReleaseHost('linux-x64', ciHost: true), host);
      } else {
        await expectLater(
          nativeReleaseHost('linux-x64', ciHost: true),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains('Ubuntu 24.04/glibc 2.39 required'),
            ),
          ),
        );
      }
    }
  });

  test(
    'PATH Node admission uses canonical executable and exact target identity',
    () async {
      final node = File(Platform.environment['ARCHWAY_TEST_NODE']!);
      final root = Directory.systemTemp.createTempSync('native-node-path-');
      addTearDown(() => root.deleteSync(recursive: true));
      final empty = Directory(p.join(root.path, 'empty'))..createSync();
      var nodePath = node.parent.path;
      if (!Platform.isWindows) {
        File(p.join(empty.path, 'node'))
            .writeAsStringSync('inert PATH candidate');
        final alias = Directory(p.join(root.path, 'alias'))..createSync();
        Link(p.join(alias.path, 'node')).createSync(node.absolute.path);
        nodePath = '${empty.path}:${alias.path}';
      }
      final driver = File(p.join(root.path, 'probe.dart'))
        ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';
import '${File('tool/ci/native_release_host.dart').absolute.uri}';
Future<void> main(List<String> args) async {
  try {
    final node = await nativeReleaseNode(args.single);
    stdout.write(jsonEncode({'executable': node.executable.path, 'identity': node.identity}));
  } catch (error) { stderr.write(error); exitCode = 17; }
}
''');
      Future<NativeProcessResult> run(
        String target,
        String path, {
        Map<String, String> extra = const {},
      }) => runNativeProcess(
        [
          Platform.resolvedExecutable,
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          driver.path,
          target,
        ],
        environment: {
          for (final entry in Platform.environment.entries)
            if (entry.key.toUpperCase() != 'PATH') entry.key: entry.value,
          ...extra,
          'PATH': path,
        },
        timeout: const Duration(seconds: 30),
      );
      final target = nativeTarget().target;
      final accepted = await run(target, nodePath);
      expect(accepted.exitCode, 0, reason: utf8.decode(accepted.stderr));
      final identity = switch (target) {
        'linux-x64' => ['v24.21.0', 'linux', 'x64'],
        'macos-arm64' => ['v24.21.0', 'darwin', 'arm64'],
        _ => ['v24.21.0', 'win32', 'x64'],
      };
      expect(jsonDecode(utf8.decode(accepted.stdout)), {
        'executable': node.resolveSymbolicLinksSync(),
        'identity': identity,
      });
      final foreign = await run(
        target == 'linux-x64' ? 'macos-arm64' : 'linux-x64',
        nodePath,
      );
      expect(foreign.exitCode, 17);
      expect(
        utf8.decode(foreign.stderr),
        contains('Wrong pinned analysis Node'),
      );
      if (!Platform.isWindows) {
        final mixedCase = await run(
          target,
          empty.path,
          extra: {'Path': node.parent.path},
        );
        expect(mixedCase.exitCode, 17);
        expect(
          utf8.decode(mixedCase.stderr),
          contains('Node is missing from PATH'),
        );
      }
      final missing = await run(target, empty.path);
      expect(missing.exitCode, 17);
      expect(
        utf8.decode(missing.stderr),
        contains('Node is missing from PATH'),
      );
    },
  );
}
