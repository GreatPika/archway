// Maintainer CI controls for explicitly prepared native acceptance fixtures.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'native_fixture_pins.dart';
import 'preparation_process.dart';

Future<void> main(List<String> args) async {
  try {
    if (args.length != 1 || !['fixtures', 'openssl'].contains(args.single)) {
      throw ArgumentError(
        'Usage: native_fixture_controls.dart fixtures|openssl',
      );
    }
    final environment = Map<String, String>.of(Platform.environment);
    final logs = Directory('build/release-native');
    Future<String> run(List<String> command, String name, int? seconds) async {
      final log = File(p.join(logs.path, '$name.log'));
      if (seconds == null) {
        // Preserve the original job-only bound for Node and fixture tests.
        final result = await Process.run(
          command.first,
          command.skip(1).toList(),
          environment: environment,
          includeParentEnvironment: false,
        );
        final output = '${result.stdout}${result.stderr}';
        writePreparation(log, output);
        stdout.write(output);
        if (result.exitCode != 0) {
          throw ProcessException(
            command.first,
            command.skip(1).toList(),
            'Fixture control failed (see ${log.path})',
            result.exitCode,
          );
        }
        return output.trim();
      }
      final output = await runPreparation(
        command,
        environment,
        log,
        timeout: Duration(seconds: seconds),
      );
      stdout.writeln(output);
      return output;
    }

    void export(String name, String value) {
      if (value.contains('\n') || value.contains('\r')) {
        throw FormatException('Invalid environment value: $name');
      }
      File(environment['GITHUB_ENV']!).writeAsStringSync(
        '$name=${value.replaceAll('\\', '/')}\n',
        mode: FileMode.append,
      );
    }

    if (args.single == 'openssl') {
      final selected = File(
        Platform.isWindows
            ? p.join(
                environment['ProgramFiles']!,
                'OpenSSL',
                'bin',
                'openssl.exe',
              )
            : Platform.isMacOS
            ? '/opt/homebrew/bin/openssl'
            : '/usr/bin/openssl',
      ).resolveSymbolicLinksSync();
      final version = await run([selected, 'version'], 'openssl-version', 30);
      if (!version.startsWith('OpenSSL ')) {
        throw const FormatException('Existing hosted OpenSSL is required');
      }
      export('ARCHWAY_TEST_OPENSSL', selected);
      return;
    }

    final fixtures = jsonDecode(
      File(
        p.join(
          environment['RUNNER_TEMP']!,
          'archway-native-fixtures',
          'acceptance-fixtures.json',
        ),
      ).readAsStringSync(),
    ) as Map<String, dynamic>;
    final sdk = Directory(fixtures['dart_sdk'] as String)
        .resolveSymbolicLinksSync();
    final dart = File(
      p.join(sdk, 'bin', Platform.isWindows ? 'dart.exe' : 'dart'),
    ).resolveSymbolicLinksSync();
    final version = await run([dart, '--version'], 'fixture-dart-version', 30);
    if (!version.startsWith('Dart SDK version: $fixtureDartVersion ')) {
      throw const FormatException('Wrong native fixture Dart version');
    }
    final nodeName = Platform.isWindows ? 'node.exe' : 'node';
    final path = environment.entries
        .firstWhere((entry) => entry.key.toLowerCase() == 'path')
        .value;
    final node = path
        .split(Platform.isWindows ? ';' : ':')
        .where((entry) => entry.isNotEmpty)
        .map((entry) => File(p.join(entry, nodeName)))
        .firstWhere((file) => file.existsSync())
        .resolveSymbolicLinksSync();
    if (await run([node, '--version'], 'fixture-node-version', null) !=
        'v24.21.0') {
      throw const FormatException('Wrong native fixture Node version');
    }
    environment.addAll({
      'ARCHWAY_TEST_DART_SDK': sdk,
      'ARCHWAY_TEST_NODE': node,
    });
    await run(
      [
        dart,
        '--suppress-analytics',
        'test',
        'test/installation_staging_test.dart',
        'test/native_fixture_capability_test.dart',
        'test/process_lifecycle_test.dart',
        'test/node_package_fixture_support_test.dart',
        'test/long_directory_test.dart',
      ],
      'fixture-keeper-tests',
      null,
    );
    if (Platform.isWindows) {
      await run(
        [
          dart,
          '--suppress-analytics',
          'test',
          'test/windows_console_test.dart',
        ],
        'windows-console-tests',
        60,
      );
      await run(
        [
          dart,
          '--suppress-analytics',
          'run',
          'test/windows_console_capability.dart',
        ],
        'windows-console-capability',
        180,
      );
    }
    export('NATIVE_DART', dart);
  } catch (error) {
    stderr.writeln('Native fixture controls failed: $error');
    exitCode = 1;
  }
}
