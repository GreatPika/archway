// Official pinned SDK preparation for private pub acceptance; never user runtime setup.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../release/archive_input.dart';
import '../release/installation_identity.dart';
import '../release/publish_directory.dart';
import '../validation/json_values.dart';
import 'installed_command_recorder.dart';
import 'native_release_host.dart';
import 'prepare_native_acceptance.dart';

const pubSdkPins = {
  'linux-x64':
      '549c182cffbdc6864df7509c16fec646c73fe6cb8a18c2cb572db1292f300cd7',
  'macos-arm64':
      'c703bcbb25ca0cc5df9109fb8272d52786ac14782437bd9e365a01985273c1cc',
  'windows-x64':
      '30c789415dcd14d3d28f8ab85a92bbd0bc6c8782f4c235d12dbd2d17f9b5d46e',
};
const pubSdkBase =
    'https://storage.googleapis.com/dart-archive/channels/stable/release/3.13.3/sdk/';
void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

Future<Map<String, Object?>> preparePubSdk({
  required String target,
  required Directory source,
  required String expectedCommit,
  required Directory output,
  File? sdkArchive,
  bool prepareCache = false,
  bool ciHost = false,
}) async {
  final actual = switch (Abi.current()) {
    Abi.linuxX64 => 'linux-x64',
    Abi.macosArm64 => 'macos-arm64',
    Abi.windowsX64 => 'windows-x64',
    _ => 'unsupported',
  };
  _require(
    target == actual && pubSdkPins.containsKey(target),
    'SDK preparation target differs from actual host',
  );
  _require(
    source.resolveSymbolicLinksSync() == source.path,
    'Expected canonical SDK preparation source',
  );
  final identity = await sourceIdentity(source);
  _require(
    identity['commit'] == expectedCommit,
    'SDK preparation source differs',
  );
  _require(
    FileSystemEntity.typeSync(output.path, followLinks: false) ==
            FileSystemEntityType.notFound &&
        output.parent.resolveSymbolicLinksSync() == output.parent.path,
    'Expected fresh canonical SDK preparation output',
  );
  final pin = pubSdkPins[target]!;
  // Local official-cache input is only a CI optimization; it cannot bypass pins.
  if (sdkArchive != null) {
    await withArchiveInput(sdkArchive, (input) async {
      _require(input.sha256 == pin, 'Official SDK archive checksum differs');
    });
  }
  final host = await nativeReleaseHost(target, ciHost: ciHost);
  final owned = await output.parent.createTemp('.archway-pub-sdk-');
  try {
    publishDirectory(owned, output);
  } catch (_) {
    await owned.delete(recursive: true);
    rethrow;
  }
  final name = 'dartsdk-$target-release.zip';
  final url = Uri.parse('$pubSdkBase$name');
  final checksum = File(p.join(output.path, '$name.sha256sum'));
  await downloadFixture(Uri.parse('$url.sha256sum'), checksum, maxBytes: 1024);
  _require(
    RegExp('^$pin\\s+\\*?${RegExp.escape(name)}\$')
        .hasMatch(checksum.readAsStringSync().trim()),
    'Official SDK checksum record differs from reviewed pin',
  );
  final archive = File(p.join(output.path, name));
  if (sdkArchive == null) {
    await downloadFixture(
      url,
      archive,
      expected: pin,
      maxBytes: 512 * 1024 * 1024,
    );
  } else {
    await withArchiveInput(sdkArchive, (input) async {
      _require(input.sha256 == pin, 'Official SDK archive checksum differs');
      await input.file.copy(archive.path);
    }, maxBytes: 512 * 1024 * 1024);
  }
  _require(
    await fixtureSha(archive) == pin,
    'Official SDK archive checksum differs',
  );
  final dart = File(
    p.join(
      output.path,
      'dart-sdk',
      'bin',
      Platform.isWindows ? 'dart.exe' : 'dart',
    ),
  );
  final environment =
      preparationEnvironment(output, dart.path, '', git: preparationGit())
        ..remove('FLUTTER_ROOT')
        ..remove('FLUTTER_SDK')
        ..remove('FLUTTER_SUPPRESS_ANALYTICS');
  final evidence = Directory(p.join(output.path, 'execution'))..createSync();
  final recorder = InstalledCommandRecorder(
    output: evidence,
    timeout: const Duration(seconds: 240),
  );
  await recorder.capture(
    officialExtractionCommand(archive.path, output.path, target, environment),
    workingDirectory: output.path,
    environment: environment,
  );
  final version = await recorder.capture(
    [dart.path, '--version'],
    workingDirectory: output.path,
    environment: environment,
  );
  final versionText = utf8.decode([
    ...version.stdout,
    ...version.stderr,
  ]).trim();
  _require(
    RegExp(r'^Dart SDK version: 3\.13\.3(?:\s|$)').hasMatch(versionText),
    'Prepared SDK version differs',
  );
  if (prepareCache) {
    await recorder.capture(
      [dart.path, '--suppress-analytics', 'pub', 'get', '--enforce-lockfile'],
      workingDirectory: source.path,
      environment: environment,
    );
  }
  _require(
    sameJson(identity, await sourceIdentity(source)),
    'SDK preparation changed source',
  );
  final report = <String, Object?>{
    'schema_version': 1,
    'target': target,
    'host': host,
    'ci_host': ciHost,
    'source': identity,
    'dart': dart.path,
    'version': versionText,
    'prepared_cache': environment['PUB_CACHE'],
    'cache_prepared': prepareCache,
    'archive': {
      'url': url.toString(),
      'size': archive.lengthSync(),
      'sha256': pin,
    },
    'commands': recorder.commands,
  };
  File(p.join(output.path, 'report.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  return report;
}

Future<void> main(List<String> arguments) async {
  try {
    final parser = ArgParser()
      ..addFlag('prepare-cache', negatable: false)
      ..addFlag('ci-host', negatable: false)
      ..addOption('sdk-archive');
    for (final name in ['target', 'source', 'expected-commit', 'output']) {
      parser.addOption(name, mandatory: true);
    }
    final args = parser.parse(arguments);
    _require(args.rest.isEmpty, 'Unexpected SDK preparation arguments');
    final archive = args['sdk-archive'] as String?;
    final report = await preparePubSdk(
      target: args['target'] as String,
      source: Directory(args['source'] as String).absolute,
      expectedCommit: args['expected-commit'] as String,
      output: Directory(args['output'] as String).absolute,
      sdkArchive: archive == null ? null : File(archive).absolute,
      prepareCache: args['prepare-cache'] as bool,
      ciHost: args['ci-host'] as bool,
    );
    stdout.writeln(jsonEncode(report));
  } catch (error) {
    stderr.writeln('Pub SDK preparation failed: $error');
    exitCode = 1;
  }
}
