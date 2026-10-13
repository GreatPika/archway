import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

// Exercise CLI.run through the real source entrypoint, with an independently
// staged installation. No shared source-tree assets are changed by these tests.
void main() {
  late Directory temporary;
  late String installation;
  late String root;

  setUpAll(() async {
    temporary = await Directory.systemTemp.createTemp('archway-vendor-');
    root = p.join(temporary.path, 'project with spaces');
    installation = p.join(root, 'installation café');
    final nativeTarget = Platform.isWindows
        ? 'windows-x64'
        : Platform.isMacOS
        ? 'macos-arm64'
        : 'linux-x64';
    for (final directory in ['bin', 'lib', 'native/$nativeTarget']) {
      await copyDirectory(directory, p.join(installation, directory));
    }
    await copyDirectory(
      'assets/typescript',
      p.join(installation, 'assets/typescript'),
      skip: 'node_modules',
    );
    final config = jsonDecode(
      await File('.dart_tool/package_config.json').readAsString(),
    ) as Map<String, dynamic>;
    final configUri = File('.dart_tool/package_config.json').absolute.uri;
    for (final package in config['packages'] as List) {
      package['rootUri'] = package['name'] == 'archway'
          ? Directory(installation).uri.toString()
          : configUri.resolve(package['rootUri'] as String).toString();
    }
    await File(p.join(installation, 'package_config.json'))
        .writeAsString(jsonEncode(config));
    await Directory(p.join(root, 'src/app')).create(recursive: true);
    await Directory(p.join(root, 'src/core')).create();
    await File(p.join(root, 'src/app/main.ts')).writeAsString(
      "import {value} from '../core/private';\nconsole.log(value);\n",
    );
    await File(p.join(root, 'src/core/private.ts'))
        .writeAsString('export const value = 1;\n');
    await File(p.join(root, 'tsconfig.json')).writeAsString(
      '{"compilerOptions":{"target":"ES2022","module":"CommonJS"},'
      '"include":["src/**/*.ts"]}',
    );
    await File(p.join(root, 'architecture.yaml')).writeAsString('''
version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes:
  - {id: app, responsibility: Application, owns: [src/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [src/core/], allows: [], public: []}
''');
  });
  tearDownAll(() => temporary.delete(recursive: true));

  Future<Map<String, dynamic>> check(int expectedExit) async {
    final process = await Process.run(
      Platform.resolvedExecutable,
      [
        '--packages=${p.join(installation, 'package_config.json')}',
        p.join(installation, 'bin/archway.dart'),
        '--root',
        root,
        'check',
      ],
      workingDirectory: temporary.path,
      // CLI stdout is UTF-8, independent of the Windows active code page.
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    expect(process.stderr, isEmpty);
    expect(process.exitCode, expectedExit, reason: process.stdout as String);
    return jsonDecode(process.stdout as String) as Map<String, dynamic>;
  }

  test(
    'source init loads the fixed installation bridge from a foreign cwd',
    () async {
      final destination = await Directory(
        p.join(temporary.path, 'new café project'),
      ).create();
      final process = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${p.join(installation, 'package_config.json')}',
          p.join(installation, 'bin/archway.dart'),
          '--root',
          destination.path,
          'init',
          '--template',
          'mixed',
        ],
        workingDirectory: temporary.path,
        environment: {'PATH': '/no-runtime-here'},
      );
      expect(process.exitCode, 0, reason: '${process.stdout}${process.stderr}');
      expect(
        File(p.join(destination.path, 'architecture.yaml')).existsSync(),
        isTrue,
      );
    },
  );
  test(
    'check trusts its in-root source installation with external Node',
    () async {
      expect(
        Directory(p.join(installation, 'assets/typescript/node_modules'))
            .existsSync(),
        isFalse,
      );
      final report = await check(1);
      expect(report['payload']['analysis_complete'], true);
      expect(report['tool_versions']['typescript'], '5.9.3');
      expect(
        report['payload']['violations'].single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    },
  );
  test(
    'selected installed source remains in corpus until explicitly excluded',
    () async {
      final policy = File(p.join(root, 'architecture.yaml'));
      final original = await policy.readAsString();
      addTearDown(() => policy.writeAsString(original));
      const selected = 'installation café/bin/archway.dart';
      final expanded = original.replaceFirst(
        'scope: [src/]',
        'scope: [src/, "$selected"]',
      );
      await policy.writeAsString(expanded);
      final included = await check(2);
      expect(
        included['payload']['coverage']['files'].any(
          (f) => f['path'] == selected,
        ),
        isTrue,
        reason: jsonEncode({
          'coverage': included['payload']['coverage']['files'],
          'unknowns': included['payload']['unknowns'],
          'tool_errors': included['payload']['tool_errors'],
        }),
      );
      await policy.writeAsString(
        expanded.replaceFirst('exclude: []', 'exclude: ["$selected"]'),
      );
      final excluded = await check(1);
      expect(
        excluded['payload']['coverage']['files'].any(
          (f) => f['path'] == selected,
        ),
        isFalse,
        reason: jsonEncode(excluded['payload']['coverage']['files']),
      );
    },
    // Two source CLI invocations can exceed the default 30-second test deadline.
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test('project compiler and parser decoys cannot replace vendor assets', () async {
    final marker = File(p.join(root, 'project-code-executed'));
    for (final path in [
      'node_modules/typescript/lib/typescript.js',
      'node_modules/yaml/dist/index.js',
      'assets/typescript/helper.cjs',
    ]) {
      final decoy = File(p.join(root, path));
      await decoy.parent.create(recursive: true);
      await decoy.writeAsString(
        "require('node:fs').writeFileSync(${jsonEncode(marker.path)}, 'executed');"
        "throw Error('Project asset executed');",
      );
    }
    final report = await check(1);
    expect(report['payload']['analysis_complete'], true);
    expect(marker.existsSync(), isFalse);
  });
  test(
    'missing vendor compiler fails even with legacy installed packages',
    () async {
      final assets = p.join(installation, 'assets/typescript');
      final legacy = Directory(p.join(assets, 'node_modules'));
      await copyDirectory(p.join(assets, 'vendor'), legacy.path);
      final compiler = File(
        p.join(assets, 'vendor/typescript/lib/typescript.js'),
      );
      final original = await compiler.readAsBytes();
      addTearDown(() async {
        await compiler.writeAsBytes(original);
        await legacy.delete(recursive: true);
      });
      await compiler.delete();
      final report = await check(2);
      expect(report['payload']['analysis_complete'], false);
      expect(
        report['payload']['tool_errors'].single['code'],
        'TYPESCRIPT_ASSETS_UNAVAILABLE',
      );
      expect(report['tool_versions']['typescript'], isNull);
    },
  );
  test('wrong vendor compiler version cannot certify a check', () async {
    final compiler = File(
      p.join(
        installation,
        'assets/typescript/vendor/typescript/lib/typescript.js',
      ),
    );
    final original = await compiler.readAsBytes();
    addTearDown(() => compiler.writeAsBytes(original));
    await compiler.writeAsString('module.exports = {version: "0.0.0"};');
    final report = await check(2);
    expect(report['payload']['analysis_complete'], false);
    expect(
      report['payload']['tool_errors'].single['code'],
      'TYPESCRIPT_VERSION_MISMATCH',
    );
    expect(report['tool_versions']['typescript'], isNull);
  });
  test('aliased vendor parser tree is rejected before loading', () async {
    final yaml = p.join(installation, 'assets/typescript/vendor/yaml');
    final backup = await Directory(yaml).rename('$yaml-backup');
    final alias = Link(yaml);
    addTearDown(() async {
      await alias.delete();
      await backup.rename(yaml);
    });
    await alias.create(backup.path);
    final report = await check(2);
    expect(report['payload']['analysis_complete'], false);
    expect(
      report['payload']['tool_errors'].single['code'],
      'TYPESCRIPT_ASSETS_UNAVAILABLE',
    );
    expect(report['tool_versions']['typescript'], isNull);
  });
  test('wrong vendor parser version cannot certify a check', () async {
    final manifest = File(
      p.join(installation, 'assets/typescript/vendor/yaml/package.json'),
    );
    final original = await manifest.readAsBytes();
    addTearDown(() => manifest.writeAsBytes(original));
    final package = jsonDecode(utf8.decode(original)) as Map<String, dynamic>;
    package['version'] = '0.0.0';
    await manifest.writeAsString(jsonEncode(package));
    final report = await check(2);
    expect(report['payload']['analysis_complete'], false);
    expect(
      report['payload']['tool_errors'].single['code'],
      'TYPESCRIPT_HELPER_FAILED',
    );
    expect(report['tool_versions']['typescript'], isNull);
  });
}

Future<void> copyDirectory(String source, String target, {String? skip}) async {
  await Directory(target).create(recursive: true);
  await for (final entity in Directory(source).list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (name == skip) continue;
    final destination = p.join(target, name);
    if (entity is Directory) {
      await copyDirectory(entity.path, destination, skip: skip);
    } else if (entity is File) {
      await entity.copy(destination);
    } else {
      throw StateError('Unexpected aliased source fixture: ${entity.path}');
    }
  }
}
