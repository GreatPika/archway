// Same-source private installed acceptance, never live pub.dev installation.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../test/support/private_pub_host.dart';
import '../npm/installed_assets.dart';
import '../npm/installed_commands.dart';
import '../npm/installed_runtimes.dart';
import '../pub/native_cache.dart';
import '../pub/stage_inventory.dart';
import '../pub/upload.dart';
import '../release/installation_identity.dart';
import '../release/publish_directory.dart';
import '../validation/json_values.dart';
import 'installed_command_recorder.dart';
import 'native_installed_commands.dart';
import 'native_release_host.dart';
import 'pub_activated_identity.dart';
import 'pub_installed_controls.dart';
import 'pub_snapshot_controls.dart';
import 'pub_stage_transport.dart';
import 'release_execution_receipts.dart';

void _require(bool condition, String message) {
  if (!condition) throw FormatException(message);
}

Map<String, Object?> _object(Object? value) {
  _require(value is Map<String, Object?>, 'Expected installed pub object');
  return value as Map<String, Object?>;
}

Future<void> inspectPubInstallation({
  required Directory source,
  required File transport,
  required Map<String, Object?> expected,
  required File descriptorFile,
  required File nativeArchive,
  required File wrongNode,
  required Directory preparedCache,
  required Directory output,
  required String commit,
  required String run,
  required String attempt,
  required String target,
  bool ciHost = false,
  bool registryReady = false,
}) async {
  _require(
    Platform.version.split(' ').first == '3.13.3',
    'Installed pub requires Dart 3.13.3',
  );
  final actualTarget = switch (Abi.current()) {
    Abi.linuxX64 => 'linux-x64',
    Abi.macosArm64 => 'macos-arm64',
    Abi.windowsX64 => 'windows-x64',
    _ => 'unsupported',
  };
  _require(
    actualTarget == target,
    'Installed pub target differs from actual host',
  );
  _require(
    source.resolveSymbolicLinksSync() == source.path,
    'Expected canonical installed source',
  );
  final identity = await sourceIdentity(source);
  _require(
    identity['commit'] == commit && sameJson(expected['source'], identity),
    'Installed pub source differs',
  );
  _require(
    FileSystemEntity.typeSync(output.path, followLinks: false) ==
            FileSystemEntityType.notFound &&
        output.parent.resolveSymbolicLinksSync() == output.parent.path,
    'Expected fresh canonical installed output',
  );
  final hostIdentity = await nativeReleaseHost(target, ciHost: ciHost);
  final node = await nativeReleaseNode(target);
  final owned = await output.parent.createTemp('.archway-pub-installed-');
  try {
    publishDirectory(owned, output);
  } catch (_) {
    await owned.delete(recursive: true);
    rethrow;
  }
  // Failed acceptance retains original diagnostics in this exclusively owned root.
  final received = Directory(p.join(output.path, 'received'));
  await readPubTransport(
    transport,
    expected,
    source,
    received,
    commit,
    run,
    attempt,
    registryReady: registryReady,
  );
  final stage = await readPubStageReceipt(
    received,
    identity,
    registryReady: registryReady,
  );
  final descriptorBytes = readOrdinaryBytes(
    descriptorFile,
    limit: maxEvidenceJsonBytes,
  );
  final descriptor = _object(decodeEvidenceJson(utf8.decode(descriptorBytes)));
  _require(
    sha256.convert(descriptorBytes).toString() ==
            stage.receipt['descriptor_sha256'] &&
        sameJson(descriptor['source'], identity) &&
        descriptor['version'] == stage.receipt['version'],
    'Installed descriptor differs from stage',
  );
  final home = Directory(p.join(output.path, 'home'))..createSync();
  final osCache = Platform.isMacOS
      ? p.join(home.path, 'Library', 'Caches')
      : home.path;
  // Private CI preparation only; the installed launcher exposes no seed/URL flag.
  final binary = await acquirePubNative(
    descriptor,
    target,
    Directory(p.join(osCache, 'archway-pub')),
    download: (_, destination, __) async {
      await nativeArchive.copy(destination.path);
    },
  );
  final installation = Directory(p.dirname(p.dirname(p.dirname(binary.path))));
  final pubCache = Directory(p.join(output.path, 'pub cache'));
  final environment = <String, String>{
    for (final entry in Platform.environment.entries)
      if (const {
        'systemroot',
        'windir',
        'comspec',
        'pathext',
        'temp',
        'tmp',
      }.contains(entry.key.toLowerCase()))
        entry.key: entry.value,
    'PATH': node.executable.parent.path,
    'HOME': home.path,
    'USERPROFILE': home.path,
    'XDG_CACHE_HOME': home.path,
    'LOCALAPPDATA': home.path,
    'XDG_CONFIG_HOME': home.path,
    'PUB_CACHE': pubCache.path,
    'DART_DATA_HOME': p.join(output.path, 'dart data'),
    'DASH__SUPPRESS_ANALYTICS': 'true',
  };
  final dart = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
  final activation = Directory(p.join(output.path, 'activation'))..createSync();
  final recorder = InstalledCommandRecorder(
    output: activation,
    timeout: const Duration(seconds: 180),
  );
  var upload = File(p.join(received.path, 'pub-package.tar.gz'));
  final privateExport = <Map<String, Object?>>[];
  if (!registryReady) {
    upload = File(p.join(output.path, 'private-upload.tar.gz'));
    final logs = Directory(p.join(output.path, 'private-export'))..createSync();
    final exporter = InstalledCommandRecorder(
      output: logs,
      timeout: const Duration(seconds: 180),
    );
    await exporter.capture(
      [
        dart,
        '--suppress-analytics',
        'pub',
        'publish',
        '--to-archive',
        upload.path,
        '--skip-validation',
      ],
      workingDirectory: p.join(received.path, 'package'),
      environment: environment,
    );
    await inspectPubUpload(upload, stage.files);
    final unchanged = await inspectPubStage(
      received,
      identity,
      registryReady: false,
    );
    _require(
      unchanged.sha256 == stage.sha256,
      'Private SDK export changed staged identity',
    );
    privateExport.addAll(exporter.commands);
  }
  final host = await PrivatePubHost.start(
    upload,
    preparedCache,
    expectedVersion: descriptor['version'] as String,
    dependencyLockfile: File(p.join(source.path, 'pubspec.lock')),
  );
  try {
    environment['PUB_HOSTED_URL'] = host.url.toString();
    await recorder.capture(
      [
        dart,
        '--suppress-analytics',
        'pub',
        'global',
        'activate',
        '--no-executables',
        'archway',
        descriptor['version'] as String,
      ],
      workingDirectory: output.path,
      environment: environment,
    );
  } finally {
    await host.close();
  }
  _require(
    !Directory(p.join(pubCache.path, 'bin')).existsSync(),
    'Unexpected generated pub command alias',
  );
  final wrapper = await inspectActivatedPubPackage(pubCache, stage.files);
  List<String> installedCommand(List<String> args) => [
    dart,
    '--suppress-analytics',
    'pub',
    'global',
    'run',
    'archway:archway',
    ...args.skip(1),
  ];
  final commandOutput = Directory(p.join(output.path, 'execution'))
    ..createSync();
  final commands = InstalledCommandRecorder(output: commandOutput);
  final work = Directory(p.join(output.path, 'commands'))..createSync();
  final checks = await runInstalledCommands(
    binary,
    installation,
    work,
    node.executable,
    commands,
    version: descriptor['version'] as String,
    environment: environment,
    command: installedCommand,
  );
  final controls = NpmInstalledControls(
    executable: binary,
    command: installedCommand,
    project: Directory(p.join(work.path, 'prepared project')),
    cwd: Directory(p.join(work.path, 'foreign')),
    wrapper: wrapper,
    payload: installation,
    target: target,
    environment: environment,
    recorder: commands,
    launcherErrorPrefix: 'archway pub launcher:',
  );
  final commandChecks = await exerciseInstalledCommands(controls);
  final bridgeInit = await exercisePubMissingBridgeInit(controls);
  final assetChecks = await exerciseInstalledAssets(controls);
  final wrongRuntime = await verifyInstalledWrongNode(controls, wrongNode);
  final missingRuntime = await exerciseInstalledNodeAbsence(
    controls,
    environment: {...environment, 'PATH': p.join(output.path, 'missing-node')},
  );
  final snapshots = await exercisePubSnapshots(
    pubCache: pubCache,
    wrapper: wrapper,
    invoke: () => controls.capture(['--help'], expectedExit: null),
  );
  final selected = _object(_object(descriptor['targets'])[target]);
  _require(
    sameJson(identity, await sourceIdentity(source)),
    'Installed acceptance changed source',
  );
  File(p.join(output.path, 'report.json')).writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({
      'schema_version': 1,
      'route': 'private-hosted-sdk-global-run',
      'status': 'passed',
      'version': descriptor['version'],
      'registry_ready': registryReady,
      'source': identity,
      'run_id': run,
      'run_attempt': attempt,
      'target': target,
      'host': hostIdentity,
      'ci_host': ciHost,
      'dart': '3.13.3',
      'node': node.identity,
      'transport': expected,
      'descriptor_sha256': stage.receipt['descriptor_sha256'],
      'native_executable': binary.path,
      'native_manifest_sha256': sha256.convert(readOrdinaryBytes(File(p.join(installation.path, 'manifest.json')))).toString(),
      'acquisition': {'mode': 'ci-verified-native', 'descriptor_sha256': stage.receipt['descriptor_sha256'], 'archive_sha256': selected['sha256'], 'manifest_sha256': selected['manifest_sha256'], 'public_cold_verified': false},
      'snapshots': snapshots,
      'private_export': privateExport,
      'activation': recorder.commands,
      'commands': commands.commands,
      'checks': checks,
      'activated_wrapper': wrapper.path,
      'command_checks': commandChecks,
      'bridge_init': bridgeInit,
      'asset_checks': assetChecks,
      'wrong_node': wrongRuntime,
      'missing_node': missingRuntime,
    })}\n',
  );
}

Future<void> main(List<String> arguments) async {
  try {
    final parser = ArgParser()
      ..addFlag('ci-host', negatable: false)
      ..addFlag('registry-ready', negatable: false);
    for (final name in [
      'source',
      'expected-source',
      'run-id',
      'run-attempt',
      'target',
      'transport',
      'expected-json',
      'descriptor',
      'native-archive',
      'wrong-node',
      'prepared-cache',
      'output',
    ]) {
      parser.addOption(name, mandatory: true);
    }
    final args = parser.parse(arguments);
    _require(args.rest.isEmpty, 'Unexpected installed pub arguments');
    final text = args['expected-json'] as String;
    _require(
      utf8.encode(text).length <= maxEvidenceJsonBytes,
      'Installed transport record exceeds bound',
    );
    await inspectPubInstallation(
      source: Directory(args['source'] as String).absolute,
      transport: File(args['transport'] as String).absolute,
      expected: _object(decodeEvidenceJson(text)),
      descriptorFile: File(args['descriptor'] as String).absolute,
      nativeArchive: File(args['native-archive'] as String).absolute,
      wrongNode: File(args['wrong-node'] as String).absolute,
      preparedCache: Directory(args['prepared-cache'] as String).absolute,
      output: Directory(args['output'] as String).absolute,
      commit: args['expected-source'] as String,
      run: args['run-id'] as String,
      attempt: args['run-attempt'] as String,
      target: args['target'] as String,
      ciHost: args['ci-host'] as bool,
      registryReady: args['registry-ready'] as bool,
    );
  } catch (error) {
    stderr.writeln('Installed pub acceptance failed: $error');
    exitCode = 1;
  }
}
