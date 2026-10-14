// Literal synthetic receipts only; never native installer acceptance.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

class InstallerEvidence {
  InstallerEvidence(this.target) {
    root = Directory.systemTemp.createTempSync('installer-receipts-');
    directory = Directory(p.join(root.path, 'installer'))..createSync();
    paths = p.Context(
      style: target == 'windows-x64' ? p.Style.windows : p.Style.posix,
    );
    final suffix = {
      'linux-x64': 'deb',
      'macos-arm64': 'pkg',
      'windows-x64': 'exe',
    }[target];
    artifact = File(
      p.join(directory.path, 'archway-0.1.0-$target-unsigned.$suffix'),
    )..writeAsStringSync('SYNTHETIC INSTALLER FIXTURE ONLY');
    final compiler = {
      'linux-x64': '/usr/bin/dpkg-deb',
      'macos-arm64': '/usr/bin/pkgbuild',
      'windows-x64': r'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
    }[target]!;
    receipt = {
      'artifact': {
        'name': p.basename(artifact.path),
        'size': artifact.lengthSync(),
        'sha256': hash(artifact.readAsBytesSync()),
      },
      'bundle_manifest_sha256': manifest,
      'compiler': {
        'path': compiler,
        'version': 'SYNTHETIC native compiler fixture',
        'sha256': 'b' * 64,
      },
      'old_fixture': {
        'version': '0.0.0',
        'test_only': true,
        'removed_file': 'obsolete/installer-probe..txt',
        'manifest_sha256': 'c' * 64,
        'artifact_sha256': 'd' * 64,
      },
      'commands': commands,
    };
    proof = {
      'target': target,
      'source': {'commit': 'f' * 40},
      'relocation': {'executed': at('relocated café installation')},
      'acceptance': {
        'scope': 'Complete applicable final native archive process suites',
        'source': {'commit': 'f' * 40},
        'source_root': at('repo'),
        'node_path': at('node'),
        'output_root': at('acceptance'),
        'fixtures': {
          'manifest': {'dart_sdk': at('dart_sdk')},
        },
        'suites': [],
        'source_suite': {},
      },
      'installer': receipt,
    };
    final bundle = at('relocated café installation'),
        old = at('test-only-old-bundle');
    final finalArtifact = at('installer/${p.basename(artifact.path)}');
    if (target == 'linux-x64') {
      add([compiler, '--version']);
      for (final pair in [
        (old, at('test-only-old.deb'), 'd' * 64),
        (bundle, finalArtifact, hash(artifact.readAsBytesSync())),
      ]) {
        add([
          dart,
          at('repo/tool/installers/linux/build.dart'),
          '--bundle',
          pair.$1,
          '--expected-commit',
          'f' * 40,
          '--output',
          pair.$2,
        ], stdout: '${pair.$3}  ${paths.basename(pair.$2)}\n');
      }
      final prefix = [
        'sudo',
        '-n',
        'dpkg',
        '--root=${at('system')}',
        '--log=${at('dpkg.log')}',
        '--force-script-chrootless',
      ];
      add([...prefix, '--install', at('test-only-old.deb')]);
      add([...prefix, '--install', finalArtifact]);
      add([...prefix, '--remove', 'archway']);
    } else if (target == 'macos-arm64') {
      add(['/usr/sbin/pkgutil', '--pkg-info', 'org.archway.cli'], exit: 1);
      add(['/usr/bin/sw_vers']);
      for (final pair in [
        (old, at('old-build'), '0.0.0', 'd' * 64),
        (bundle, at('final-build'), '0.1.0', hash(artifact.readAsBytesSync())),
      ]) {
        add(
          [
            dart,
            at('repo/tool/installers/macos/build.dart'),
            '--bundle',
            pair.$1,
            '--output',
            pair.$2,
          ],
          stdout:
              '${pair.$4}  ${paths.join(pair.$2, 'archway-${pair.$3}-macos-arm64-unsigned.pkg')}\n',
        );
      }
      for (final package in [
        at('old-build/archway-0.0.0-macos-arm64-unsigned.pkg'),
        finalArtifact,
      ]) {
        add([
          'sudo',
          '-n',
          '/usr/sbin/installer',
          '-pkg',
          package,
          '-target',
          '/',
        ]);
      }
      add(['sudo', '-n', '/bin/sh', '/usr/local/lib/archway/uninstall.sh']);
      add(['/usr/sbin/pkgutil', '--pkg-info', 'org.archway.cli'], exit: 1);
    } else {
      add([compiler, '/?']);
      for (final item in [
        ('old', old, '0.0.0', at('old-artifact')),
        ('final', bundle, '0.1.0', at('installer')),
      ]) {
        final inputs = at('${item.$1}-input');
        add([
          dart,
          at('repo/tool/installers/windows/prepare.dart'),
          item.$2,
          inputs,
        ]);
        add([
          compiler,
          '/DAppVersion=${item.$3}',
          '/DOutputDir=${item.$4}',
          paths.join(inputs, 'archway.iss'),
        ]);
      }
      final installed = at('installed');
      receipt['installed'] = {'installation_root': installed};
      for (final exe in [
        at('old-artifact/archway-0.0.0-windows-x64-unsigned.exe'),
        finalArtifact,
        paths.join(installed, 'unins000.exe'),
      ]) {
        add([exe, '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-']);
      }
    }
  }
  final String target;
  late final Directory root, directory;
  late final File artifact;
  late final p.Context paths;
  late final Map<String, dynamic> proof, receipt;
  final commands = <Map<String, dynamic>>[];
  final manifest = 'a' * 64;
  String at(String name) => paths.joinAll([
    target == 'windows-x64' ? r'C:\fixture' : '/fixture',
    ...name.split('/'),
  ]);
  String get dart => at(
    target == 'windows-x64' ? 'dart_sdk/bin/dart.exe' : 'dart_sdk/bin/dart',
  );
  static String hash(List<int> bytes) => sha256.convert(bytes).toString();
  Map<String, dynamic> record(
    List<String> argv,
    String prefix, {
    int exit = 0,
    String stdout = 'SYNTHETIC phase output\n',
    String stderr = '',
  }) {
    final value = <String, dynamic>{'arguments': argv, 'exit': exit};
    for (final stream in ['stdout', 'stderr']) {
      final bytes = utf8.encode(stream == 'stdout' ? stdout : stderr);
      final name = '$prefix.$stream.log';
      File(p.join(directory.path, name)).writeAsBytesSync(bytes);
      value[stream] = name;
      value['${stream}_sha256'] = hash(bytes);
    }
    return value;
  }

  void add(
    List<String> argv, {
    int exit = 0,
    String stdout = 'SYNTHETIC phase output\n',
  }) => commands.add(
    record(argv, 'phase-${commands.length}', exit: exit, stdout: stdout),
  );
}
