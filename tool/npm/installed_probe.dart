// Actual npm-owned routes from one admitted packed candidate. No cache seeding.
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../ci/installed_command_recorder.dart';
import '../ci/native_installed_commands.dart';
import '../ci/native_release_host.dart';
import 'installed_assets.dart';
import 'installed_commands.dart';
import 'installed_identity.dart';
import 'installed_route.dart';
import 'installed_runtimes.dart';
import 'installed_termination.dart';
import 'prepare_native.dart';

Future<Map<String, Object?>> inspectNpmRoute({
  required File archive,
  required Map<String, Object?> receipt,
  required String target,
  required String routeName,
  required File node,
  required File npmCli,
  required File wrongNode,
  required Directory output,
  File? nativeArchive,
}) async {
  if (!['local', 'global', 'cache'].contains(routeName))
    throw ArgumentError.value(routeName);
  if (FileSystemEntity.typeSync(output.path, followLinks: false) !=
          FileSystemEntityType.notFound ||
      output.parent.resolveSymbolicLinksSync() != output.parent.path) {
    throw StateError(
      'Installed probe needs an absent output in a canonical parent',
    );
  }
  output.createSync();
  final work = Directory(p.join(output.path, 'npm installed café'))
    ..createSync();
  final project = Directory(p.join(work.path, 'project'))..createSync();
  File(p.join(project.path, 'package.json'))
      .writeAsStringSync('{"private":true}');
  final home = Directory(p.join(work.path, 'home'))..createSync();
  final userCache = Platform.isMacOS
      ? p.join(home.path, 'Library/Caches')
      : p.join(home.path, 'cache');
  final environment =
      installedRuntimeEnvironment(Platform.environment, node.parent.path)
        ..removeWhere(
          (key, _) => {
            'home',
            'userprofile',
            'localappdata',
            'xdg_cache_home',
          }.contains(key.toLowerCase()),
        )
        ..addAll({
          'HOME': home.path,
          'USERPROFILE': home.path,
          'LOCALAPPDATA': userCache,
          'XDG_CACHE_HOME': userCache,
          'npm_config_cache': p.join(work.path, 'npm cache'),
          'npm_config_offline': 'true',
          'npm_config_ignore_scripts': 'true',
          'npm_config_registry': 'http://127.0.0.1:9',
          'npm_config_audit': 'false',
          'npm_config_fund': 'false',
        });
  for (final name in ['userconfig', 'globalconfig']) {
    final file = File(p.join(work.path, '$name.npmrc'))..writeAsStringSync('');
    environment['npm_config_$name'] = file.path;
  }
  final logs = Directory(p.join(output.path, 'processes'))..createSync();
  late NpmInstalledRoute route;
  final recorder = InstalledCommandRecorder(
    output: logs,
    timeout: Duration(seconds: routeName == 'cache' ? 120 : 30),
    windowsCommandFor: (arguments) => route.windowsCommandFor(arguments),
  );
  route = NpmInstalledRoute(
    route: routeName,
    archive: archive,
    node: node,
    npmCli: npmCli,
    project: project,
    installation: routeName == 'local'
        ? project
        : Directory(p.join(work.path, 'prefix')),
    environment: environment,
    recorder: recorder,
  );
  final phases = <Map<String, Object?>>[];
  final proof = <String, Object?>{
    'schema_version': 1,
    'route': routeName,
    'target': target,
    'source': receipt['source'],
    'version': receipt['version'],
    'registry_ready': receipt['registry_ready'],
    'tarball_sha256': receipt['sha256'],
    'descriptor_sha256': receipt['descriptor_sha256'],
    'phases': phases,
    'process_directory': 'processes',
    'archive_path': archive.path,
    'node_executable': node.path,
    'npm_cli': npmCli.path,
    'npm': '11.19.0',
    'source_commit': (receipt['source'] as Map)['commit'],
    'run_id': Platform.environment['GITHUB_RUN_ID'],
    'run_attempt': Platform.environment['GITHUB_RUN_ATTEMPT'],
  };
  void save() => File(p.join(output.path, 'report.json')).writeAsStringSync(
    '${jsonEncode({...proof, 'processes': recorder.commands})}\n',
  );
  try {
    final npmVersion = await recorder.capture(
      [node.path, npmCli.path, '--version'],
      workingDirectory: work.path,
      environment: environment,
    );
    if (utf8.decode(npmVersion.stdout).trim() != '11.19.0' ||
        npmVersion.stderr.isNotEmpty) {
      throw StateError('Wrong pinned npm runtime');
    }
    await route.install();
    final descriptor = await readInstalledNpmDescriptor(
      route.packageRoot,
      receipt,
    );
    final pin = (descriptor['targets'] as Map)[target] as Map;
    final cache = Directory(p.join(userCache, 'archway/npm'));
    if (nativeArchive != null) {
      await prepareNpmNative(
        wrapper: route.packageRoot,
        cache: cache,
        target: target,
        receipt: receipt,
        archive: nativeArchive,
        node: node,
        environment: environment,
        recorder: recorder,
        workingDirectory: work,
      );
    }
    proof['acquisition'] = {
      'mode': nativeArchive == null
          ? 'public-https-cold'
          : 'ci-verified-native',
      'descriptor_sha256': receipt['descriptor_sha256'],
      'archive_sha256': pin['sha256'],
      'manifest_sha256': pin['manifest_sha256'],
      'public_cold_verified': false,
    };
    await recorder.capture(
      route.invocation(['--help']),
      workingDirectory: work.path,
      environment: environment,
      timeout: const Duration(seconds: 150),
    );
    final selected = await inspectNpmNativeCache(
      wrapper: route.packageRoot,
      cache: Directory(p.join(userCache, 'archway/npm')),
      target: target,
      receipt: receipt,
    );
    (proof['acquisition'] as Map)['public_cold_verified'] =
        nativeArchive == null;
    proof['native_source'] = selected.descriptor['source'];
    proof['cache_selection'] = route.cacheSelection;
    for (final phase
        in routeName == 'cache' ? ['cached'] : ['installed', 'relocated']) {
      if (phase == 'relocated')
        route.relocate(Directory(p.join(work.path, 'relocated ü')));
      final base = Directory(p.join(work.path, '$phase checks'))..createSync();
      final inspectedProject = routeName == 'local'
          ? route.installation
          : (Directory(p.join(base.path, 'analysis project'))..createSync());
      List<String> command(List<String> arguments) =>
          route.invocation(arguments.skip(1).toList());
      final ranges = <String, Object?>{};
      Future<T> group<T>(String name, Future<T> Function() operation) async {
        final start = recorder.commands.length;
        final value = await operation();
        ranges[name] = [start, recorder.commands.length];
        return value;
      }

      final core = await group(
        'core',
        () => runInstalledCommands(
          route.shim,
          selected.payload,
          base,
          node,
          recorder,
          version: receipt['version'] as String,
          environment: environment,
          command: command,
          projectRoot: inspectedProject,
        ),
      );
      final controls = NpmInstalledControls(
        executable: route.shim,
        command: command,
        project: inspectedProject,
        cwd: Directory(p.join(base.path, 'foreign')),
        wrapper: route.packageRoot,
        payload: selected.payload,
        target: target,
        environment: environment,
        recorder: recorder,
      );
      final phaseReceipt = <String, Object?>{
        'phase': phase,
        'process_ranges': ranges,
        'command_prefix': route.invocation([]),
        'shim': route.shim.path,
        'wrapper': route.packageRoot.path,
        'payload': selected.payload.path,
        'project': inspectedProject.path,
        'cwd': controls.cwd.path,
        'core': core,
        'assets': await group(
          'assets',
          () => exerciseInstalledAssets(controls),
        ),
        'commands': await group(
          'commands',
          () => exerciseInstalledCommands(controls),
        ),
        'runtimes': await group(
          'runtimes',
          () => exerciseInstalledRuntimes(controls, wrongNode: wrongNode),
        ),
        'corpus': await group(
          'corpus',
          () => exerciseInstalledCorpus(
            controls,
            selected: File(p.join(route.packageRoot.path, 'bin/archway.cjs')),
          ),
        ),
      };
      final previousLogs = logs.listSync().map((entry) => entry.path).toSet();
      phaseReceipt['termination'] = await group(
        'termination',
        () => exerciseInstalledTermination(
          controls,
          node: node,
          cacheRoute: routeName == 'cache',
        ),
      );
      final addedLogs = logs
          .listSync()
          .whereType<Directory>()
          .where((entry) => !previousLogs.contains(entry.path))
          .toList();
      if (addedLogs.length != 1 ||
          !p.basename(addedLogs.single.path).startsWith('termination-')) {
        throw StateError('Expected one owned termination evidence directory');
      }
      phaseReceipt['termination_directory'] = p.basename(addedLogs.single.path);
      phases.add(phaseReceipt);
      save();
    }
    proof['status'] = 'passed';
    return proof;
  } catch (error) {
    proof['status'] = 'failed';
    proof['error'] = error.toString();
    rethrow;
  } finally {
    save();
  }
}

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('packed-directory', mandatory: true)
    ..addOption('expected-commit', mandatory: true)
    ..addOption('target', mandatory: true)
    ..addOption('route', mandatory: true, allowed: ['local', 'global', 'cache'])
    ..addOption('npm-cli', mandatory: true)
    ..addOption('wrong-node', mandatory: true)
    ..addOption('native-archive')
    ..addOption('output', mandatory: true)
    ..addFlag('registry-ready', negatable: false)
    ..addFlag('ci-host', negatable: false);
  try {
    final args = parser.parse(arguments);
    if (args.rest.isNotEmpty)
      throw ArgumentError('Unexpected npm probe arguments');
    final target = args['target'] as String;
    final host = await nativeReleaseHost(
      target,
      ciHost: args['ci-host'] as bool,
    );
    final node = await nativeReleaseNode(target);
    await withNpmPackedCandidate(
      Directory(args['packed-directory'] as String).absolute,
      expectedCommit: args['expected-commit'] as String,
      registryReady: args['registry-ready'] as bool,
      inspect: (archive, receipt) async {
        final result = await inspectNpmRoute(
          archive: archive,
          receipt: receipt,
          target: target,
          routeName: args['route'] as String,
          node: node.executable,
          npmCli: File(args['npm-cli'] as String).absolute,
          wrongNode: File(args['wrong-node'] as String).absolute,
          nativeArchive: args['native-archive'] == null
              ? null
              : File(args['native-archive'] as String).absolute,
          output: Directory(args['output'] as String).absolute,
        );
        final report = File(p.join(args['output'] as String, 'report.json'));
        final saved = jsonDecode(report.readAsStringSync()) as Map;
        report.writeAsStringSync(
          '${jsonEncode({...saved, ...result, 'host': host, 'ci_host_verified': args['ci-host'], 'node': node.identity})}\n',
        );
      },
    );
  } catch (error) {
    stderr.writeln(error);
    exitCode = 1;
  }
}
