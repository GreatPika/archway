// Real AOT check transport, schemas, helper faults and input rechecks.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import '../tool/validation/json_values.dart';
import 'support/check_inventory_fixture.dart';
import 'support/installation_staging.dart';
import 'support/native_process_support.dart';

void check(bool condition, [Object? details]) {
  if (!condition) throw StateError('Check process assertion failed: $details');
}

bool containsJson(dynamic entries, Object value) =>
    (entries as List).any((e) => sameJson(e, value));
String fileUri(String path) => File(path).uri.toString();
String inventoryHash(List<dynamic> entries) =>
    sha256.convert(utf8.encode(jsonEncode(entries))).toString();

// The wrapper owns a synchronous direct child. Its inner deadline must fire
// before the outer runner can terminate the wrapper and orphan that child.
Future<NativeProcessResult> captureCheckHelper(
  String node,
  String helper,
  String request,
) => runNativeProcess(
  [
    node,
    '-e',
    r'''const result=require('node:child_process').spawnSync(process.execPath,[process.argv[1]],{
input:process.argv[2],timeout:10000,killSignal:'SIGKILL',maxBuffer:64*1024*1024});
if(result.error)throw result.error;
if(result.signal!==null || result.status===null)throw Error('Helper signal: '+result.signal);
process.stdout.write(result.stdout);process.stderr.write(result.stderr);process.exitCode=result.status;
''',
    helper,
    request,
  ],
  timeout: const Duration(seconds: 15),
  environment: {
    for (final entry in Platform.environment.entries)
      if (!entry.key.startsWith('NODE_')) entry.key: entry.value,
  },
);

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2)
    throw ArgumentError('Usage: check_process_smoke.dart <executable> <node>');
  final repository = File.fromUri(Platform.script).parent.parent;
  final node = File(arguments[1]).resolveSymbolicLinksSync();
  final schema = ContractSchema(
    jsonDecode(
      File(p.join(repository.path, 'contracts/json/public-result.schema.json'))
          .readAsStringSync(),
    ),
  );
  var count = 0;
  final temporary = Directory.systemTemp.createTempSync(
    'archway-check-process-',
  );
  final base = Directory(temporary.resolveSymbolicLinksSync());
  try {
    final root = Directory(p.join(base.path, 'project with spaces'));
    final install = Directory(p.join(root.path, 'installation café'))
      ..createSync(recursive: true);
    final binary = stageInstallation(File(arguments[0]), install);
    File at(String path) => File(p.join(root.path, path));
    Directory(at('src/app').path).createSync(recursive: true);
    Directory(at('src/core').path).createSync();
    at('src/app/main.ts')
        .writeAsStringSync("import {value} from '../core/private';\n");
    at('src/core/private.ts').writeAsStringSync('export const value = 1;\n');
    at('tsconfig.json').writeAsStringSync(
      '{"compilerOptions":{"target":"ES2022","module":"CommonJS"},"include":["src/**/*.ts"]}',
    );
    at('architecture.yaml').writeAsStringSync('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes:
  - {id: app, responsibility: Application, owns: [src/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [src/core/], allows: [], public: []}
''');
    Future<dynamic> invoke(
      int expected, [
      Map<String, String> env = const {},
    ]) async {
      final result = await runNativeProcess(
        [binary.path, '--root', root.path, 'check'],
        workingDirectory: base.path,
        environment: {...Platform.environment, 'PATH': p.dirname(node), ...env},
        timeout: const Duration(seconds: 15),
      );
      check(result.exitCode == expected, '$count: $result');
      check(result.stderr.isEmpty, result.stderr);
      check(
        result.stdout.isNotEmpty &&
            result.stdout.last == 10 &&
            result.stdout.where((b) => b == 10).length == 1,
        result.stdout,
      );
      final value = jsonDecode(utf8.decode(result.stdout));
      check(schema.errors(value).isEmpty, schema.errors(value));
      check(value['exit_code'] == result.exitCode, value);
      count++;
      return value;
    }

    Future<NativeProcessResult> nodeScript(String script) => runNativeProcess([
      node,
      '-e',
      script,
    ], timeout: const Duration(seconds: 15));
    Future<void> link(String target, String path, String type) async {
      final result = await nodeScript(
        "require('node:fs').symlinkSync(${jsonEncode(target)},${jsonEncode(path)},${jsonEncode(type)});",
      );
      check(result.exitCode == 0, result);
    }

    var marker = at('project-decoy-executed');
    for (final relative in [
      'assets/typescript/helper.cjs',
      'node_modules/typescript/lib/typescript.js',
    ]) {
      final decoy = at(relative);
      decoy.parent.createSync(recursive: true);
      decoy.writeAsStringSync(
        "require('node:fs').writeFileSync(${jsonEncode(marker.path)},'executed');throw Error('decoy');",
      );
    }
    var result = await invoke(1);
    check(!marker.existsSync());
    check(result['payload']['analysis_complete'] == true);
    check(
      result['payload']['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED',
    );
    check(result['tool_versions']['typescript'] == '5.9.3');
    final originalPayload = result['payload'];
    Directory(at('node_modules').path).deleteSync(recursive: true);
    Directory(at('assets').path).deleteSync(recursive: true);
    check(
      (await invoke(1, {
            'NODE_OPTIONS': '--require=/no-project-loader.cjs',
            'NODE_PATH': root.path,
          }))['payload']['analysis_complete'] ==
          true,
    );
    final helper = File(p.join(install.path, 'assets/typescript/helper.cjs'));
    marker = at('executed-project-code');
    final projectHelper = at('project-helper.cjs')
      ..writeAsStringSync(
        "require('node:fs').writeFileSync(${jsonEncode(marker.path)},'executed');process.stdout.write('{}');",
      );
    for (final asset in [
      helper,
      File(p.join(helper.parent.path, 'framing.cjs')),
      File(p.join(helper.parent.path, 'trace.cjs')),
      File(p.join(helper.parent.path, 'vendor/typescript/lib/typescript.js')),
    ]) {
      final original = asset.readAsBytesSync();
      asset.deleteSync();
      await link(projectHelper.path, asset.path, 'file');
      result = await invoke(2);
      check(!marker.existsSync(), 'Symlinked asset executed project code');
      check(
        result['payload']['tool_errors'][0]['code'] ==
            'TYPESCRIPT_ASSETS_UNAVAILABLE',
      );
      Link(asset.path).deleteSync();
      asset.writeAsBytesSync(original);
    }
    final compilerPackage = Directory(
      p.join(helper.parent.path, 'vendor/typescript'),
    );
    final backupPackage = Directory('${compilerPackage.path}-backup');
    compilerPackage.renameSync(backupPackage.path);
    await link(root.path, compilerPackage.path, 'dir');
    check(
      (await invoke(2))['payload']['tool_errors'][0]['code'] ==
          'TYPESCRIPT_ASSETS_UNAVAILABLE',
    );
    Link(compilerPackage.path).deleteSync();
    backupPackage.renameSync(compilerPackage.path);
    final protocol =
        jsonDecode(
              File(
                p.join(repository.path, 'contracts/helper/request.schema.json'),
              ).readAsStringSync(),
            )['properties']['protocol_version']['const']
            as int;
    final request = {
      'protocol_version': protocol,
      'request_id': 'check:web',
      'project_id': 'web',
      'root_uri': root.uri.toString().replaceFirst(RegExp(r'/$'), ''),
      'config_path': 'tsconfig.json',
      'expected_files': ['src/app/main.ts', 'src/core/private.ts'],
    };
    // Real helper stdin, with raw stdout/stderr and exit forwarded unchanged.
    final capture = await captureCheckHelper(
      node,
      helper.path,
      jsonEncode(request),
    );
    check(capture.exitCode == 0 && capture.stderr.isEmpty, capture);
    final captured = capture.stdout;
    final envelope = jsonDecode(utf8.decode(captured));
    check(
      envelope['status'] == 'complete' &&
          (envelope['facts'] as List).isNotEmpty,
      envelope,
    );
    dynamic clone() => jsonDecode(utf8.decode(captured));
    void canned(
      List<int> raw, {
      int exitCode = 0,
      String before = '',
    }) => helper.writeAsStringSync(
      "process.stdin.resume();process.stdin.on('end',()=>{$before process.stdout.write(Buffer.from('${base64Encode(raw)}','base64'));process.exitCode=$exitCode;});",
    );
    void cannedJson(dynamic value) => canned(utf8.encode(jsonEncode(value)));
    Future<void> emptyEdges() async =>
        check(sameJson((await invoke(2))['payload']['facts']['edges'], []));
    canned([239, 187, 191, ...captured]);
    result = await invoke(2);
    check(sameJson(result['payload']['facts']['edges'], []));
    check(
      result['payload']['tool_errors'][0]['code'] == 'TYPESCRIPT_HELPER_FAILED',
    );
    final text = utf8.decode(captured);
    for (final raw in [
      [...captured, ...utf8.encode('{}')],
      [...captured, ...utf8.encode(' trailing')],
      utf8.encode(text.trimRight().substring(0, text.trimRight().length - 1)),
      [255],
      utf8.encode(text.replaceFirst('"path":', r'"path":null,"p\u0061th":')),
      utf8.encode(
        text.replaceFirst(
          '"protocol_version":$protocol',
          '"protocol_version":$protocol,"protocol_version":$protocol',
        ),
      ),
    ]) {
      canned(raw);
      await emptyEdges();
    }
    for (final edit in <void Function(dynamic)>[
      (e) => e['extra'] = true,
      (e) => e['protocol_version'] = protocol + 1,
      (e) => e['project_id'] = 'other-project',
      (e) => e.remove('files'),
      (e) => e['files'] = (e['files'] as List).reversed.toList(),
      (e) => e['facts'][0]['source_range']['start']['extra'] = 1,
      (e) => e['inputs'].add(e['inputs'][0]),
      (e) {
        e['status'] = 'failed';
        e['tool_errors'] = [];
      },
      (e) => e['files'][0]['coverage'] = 'partial',
      (e) => e['request_id'] = 'another-request',
      (e) => e['facts'][0]['source_range']['end']['line'] = 99,
      (e) => e['facts'][0]['input_ids'] = ['missing-evidence'],
      (e) => e['files'][0].addAll({
        'membership': 'nonmember',
        'coverage': 'not_applicable',
        'input_id': null,
      }),
    ]) {
      final changed = clone();
      edit(changed);
      cannedJson(changed);
      await emptyEdges();
    }
    var changed = clone();
    final targetUri = fileUri(at('src/core/bad*.ts').path)
        .replaceAll('%2A', '*');
    changed['inputs'].add({
      'id': 'bad-target',
      'kind': 'file',
      'observed_uri': targetUri,
      'canonical_uri': targetUri,
      'sha256': 'a' * 64,
      'symlink_hops': [],
    });
    changed['facts'][0]['resolution'].addAll({
      'path': 'src/core/bad*.ts',
      'canonical_file_uri': targetUri,
    });
    changed['facts'][0]['input_ids'].add('bad-target');
    cannedJson(changed);
    await emptyEdges();
    for (final via in [
      fileUri(at('missing.ts').path),
      envelope['facts'][0]['resolution']['canonical_file_uri'],
    ]) {
      changed = clone();
      changed['facts'][0]['resolution']['via_path'] = via;
      cannedJson(changed);
      await emptyEdges();
    }
    for (final kind in ['absent', 'file']) {
      changed = clone();
      changed['inputs'].add({
        'symlink_hops': [],
        'id': 'root-input',
        'kind': kind,
        'observed_uri': 'file:///',
        'canonical_uri': kind == 'absent' ? null : 'file:///',
        if (kind == 'file') 'sha256': 'a' * 64,
      });
      cannedJson(changed);
      await emptyEdges();
    }
    if (Platform.isWindows) {
      final folder = Directory(p.join(base.path, 'junction-inventory'))
        ..createSync();
      final target = Directory(p.join(folder.path, 'target'))..createSync();
      final junction = p.join(folder.path, 'alias');
      final create = await runNativeProcess([
        'cmd.exe',
        '/d',
        '/c',
        'mklink',
        '/J',
        junction,
        target.path,
      ], timeout: const Duration(seconds: 15));
      check(create.exitCode == 0, create);
      final metadata = windowsReparseMetadata(junction);
      check(
        metadata.attributes & 0x400 != 0 && metadata.tag == 0xa0000003,
        metadata,
      );
      check(
        metadata.tag != 0xa000000c,
        'Control must be junction, not symbolic link',
      );
      final expectedEntries = [
        ['alias', 'symlink'],
        ['target', 'directory'],
      ];
      check(
        sameJson(await inventoryEntries(folder.path, node), expectedEntries),
      );
      final uri = fileUri(folder.path);
      for (final (entries, expectedExit) in [
        (
          [
            ['alias', 'directory'],
            ['target', 'directory'],
          ],
          2,
        ),
        (expectedEntries, 1),
      ]) {
        changed = clone();
        final digest = inventoryHash(entries);
        changed['inputs'].add({
          'id': 'junction-inventory',
          'kind': 'directory',
          'symlink_hops': [],
          'observed_uri': uri,
          'canonical_uri': uri,
          'sha256': digest,
        });
        cannedJson(changed);
        result = await invoke(expectedExit);
        final identity = result['payload']['input_identity'];
        check(identity['rechecked'] == true);
        if (expectedExit == 2) {
          check(
            sameJson(identity['changed_inputs'], [
              {'kind': 'external', 'canonical_file_uri': uri},
            ]),
          );
        } else {
          check(sameJson(identity['changed_inputs'], []));
          check(
            containsJson(identity['inputs'], {
              'kind': 'inventory',
              'location': {'kind': 'external', 'canonical_file_uri': uri},
              'presence': 'present',
              'hash': 'sha256:$digest',
            }),
          );
        }
      }
      Link(junction).deleteSync();
      target.deleteSync();
      folder.deleteSync();
      stdout.writeln(
        'Native junction inventory: directory hash rejected; symlink hash accepted.',
      );
    }
    changed = clone();
    final filesystemRoot = p.rootPrefix(root.path);
    final filesystemRootUri = fileUri(filesystemRoot);
    final rootEntries = await inventoryEntries(filesystemRoot, node);
    final rootHash = inventoryHash(rootEntries);
    changed['inputs'].add({
      'id': 'filesystem-root',
      'kind': 'directory',
      'symlink_hops': [],
      'observed_uri': filesystemRootUri,
      'canonical_uri': filesystemRootUri,
      'sha256': rootHash,
    });
    cannedJson(changed);
    final attributesBefore = Platform.isWindows
        ? windowsInventoryAttributes(filesystemRoot, rootEntries)
        : <dynamic>[];
    final blockedBefore = attributesBefore
        .where((e) => e['win32_error'] != null)
        .toList();
    check(blockedBefore.every((e) => e['win32_error'] == 32), blockedBefore);
    try {
      result = await invoke(blockedBefore.isNotEmpty ? 2 : 1);
      check(
        sameJson(await inventoryEntries(filesystemRoot, node), rootEntries),
      );
      if (Platform.isWindows) {
        final blockedAfter = windowsInventoryAttributes(
          filesystemRoot,
          rootEntries,
        ).where((e) => e['win32_error'] != null).toList();
        check(sameJson(blockedAfter, blockedBefore), [
          blockedBefore,
          blockedAfter,
        ]);
      }
    } catch (_) {
      final diagnostic = <String, dynamic>{
        'root_inventory': filesystemRootUri,
        'expected_entries': rootEntries,
        'expected_hash': rootHash,
      };
      try {
        final after = await inventoryEntries(filesystemRoot, node);
        diagnostic.addAll({
          'after_entries': after,
          'after_hash': inventoryHash(after),
        });
      } catch (error) {
        diagnostic['after_scan_error'] = '$error';
      }
      if (Platform.isWindows) {
        try {
          diagnostic['windows_attributes'] = windowsInventoryAttributes(
            filesystemRoot,
            rootEntries,
          );
        } catch (error) {
          diagnostic['windows_attribute_error'] = '$error';
        }
      }
      stderr.writeln(jsonEncode(diagnostic));
      rethrow;
    }
    final payload = result['payload'], identity = payload['input_identity'];
    check(
      containsJson(identity['inputs'], {
        'kind': 'inventory',
        'location': {
          'kind': 'external',
          'canonical_file_uri': filesystemRootUri,
        },
        'presence': 'present',
        'hash': 'sha256:$rootHash',
      }),
    );
    check(sameJson(payload['facts'], originalPayload['facts']));
    check(sameJson(payload['violations'], originalPayload['violations']));
    check(
      sameJson(payload['unknowns'], []) &&
          sameJson(identity['changed_inputs'], []),
    );
    if (blockedBefore.isNotEmpty) {
      check(
        result['status'] == 'incomplete' &&
            payload['analysis_complete'] == false,
      );
      check(identity['rechecked'] == false);
      final message =
          "FileSystemException: Directory entry is unrepresentable or changed, path = '$filesystemRoot'";
      check(
        sameJson(
          [
            for (final e in payload['tool_errors']) [e['code'], e['message']],
          ],
          [
            ['INPUT_RECHECK_FAILED', message],
          ],
        ),
      );
      stdout.writeln(
        'Filesystem-root positive proof unavailable: native attribute access blocked ${jsonEncode(blockedBefore)}; fail-closed root recheck verified.',
      );
    } else {
      check(
        result['status'] == 'negative' && payload['analysis_complete'] == true,
      );
      check(
        identity['rechecked'] == true && sameJson(payload['tool_errors'], []),
      );
      stdout.writeln('Filesystem-root positive inventory proof passed.');
    }
    canned(captured, exitCode: 1);
    await emptyEdges();
    final failed = clone();
    failed.addAll({
      'status': 'failed',
      'tool_errors': [
        {
          'code': 'PROJECT_FAILURE',
          'message': 'Injected project failure',
          'path': null,
          'source_range': null,
        },
      ],
    });
    cannedJson(failed);
    result = await invoke(2);
    check(
      result['payload']['facts']['edges'][0]['resolution']['kind'] == 'local',
    );
    check(
      result['payload']['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED',
    );
    final originalConfig = at('tsconfig.json').readAsStringSync();
    canned(
      captured,
      before:
          "require('node:fs').appendFileSync(${jsonEncode(at('tsconfig.json').path)},'\\n');",
    );
    result = await invoke(2);
    check(
      containsJson(result['payload']['input_identity']['changed_inputs'], {
        'kind': 'repository',
        'path': 'tsconfig.json',
      }),
    );
    check(
      result['payload']['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED',
    );
    at('tsconfig.json').writeAsStringSync(originalConfig);
    canned(
      captured,
      before:
          "require('node:fs').mkdirSync(${jsonEncode(at('node_modules').path)});",
    );
    result = await invoke(2);
    check(
      containsJson(result['payload']['input_identity']['changed_inputs'], {
        'kind': 'repository',
        'path': 'node_modules',
      }),
    );
    Directory(at('node_modules').path).deleteSync();
    final newSource = at('src/app/new.ts');
    canned(
      captured,
      before:
          "require('node:fs').writeFileSync(${jsonEncode(newSource.path)},'export {};');",
    );
    result = await invoke(2);
    check(
      containsJson(result['payload']['input_identity']['changed_inputs'], {
        'kind': 'repository',
        'path': 'src/app',
      }),
    );
    newSource.deleteSync();
    canned(
      captured,
      before: 'process.stderr.write(Buffer.alloc(256*1024,120));',
    );
    check((await invoke(1))['payload']['analysis_complete'] == true);
    canned(
      captured,
      before: 'process.stderr.write(Buffer.alloc(256*1024+1,120));',
    );
    await emptyEdges();
    canned(
      captured,
      before: 'process.stdout.write(Buffer.alloc(64*1024*1024+1,32));',
    );
    await emptyEdges();
    final realHelper = File(p.join(helper.parent.path, 'real-helper.cjs'));
    final helperSource = File(
      p.join(repository.path, 'assets/typescript/helper.cjs'),
    ).readAsBytesSync();
    realHelper.writeAsBytesSync(helperSource);
    helper.writeAsStringSync(
      "const fs=require('node:fs'),original=fs.statSync;let first=true;fs.statSync=function(file,...args){if(first && String(file)===${jsonEncode(at('src/core/private.ts').path)}){first=false;return original(${jsonEncode(at('src/core').path)},...args);}return original(file,...args);};require('./real-helper.cjs');",
    );
    result = await invoke(2);
    check(
      (result['payload']['tool_errors'] as List).any(
        (e) => e['code'] == 'TYPESCRIPT_INPUT_TRACE_FAILED',
      ),
    );
    helper.writeAsBytesSync(helperSource);
    final compiler = File(
      p.join(helper.parent.path, 'vendor/typescript/lib/typescript.js'),
    );
    final originalCompiler = compiler.readAsStringSync();
    check(originalCompiler.contains('var version = "5.9.3";'));
    compiler.writeAsStringSync(
      originalCompiler.replaceFirst(
        'var version = "5.9.3";',
        'var version = "0.0.0";',
      ),
    );
    result = await invoke(2);
    check(result['tool_versions']['typescript'] == null);
    check(sameJson(result['payload']['facts']['edges'], []));
    check(
      result['payload']['tool_errors'][0]['code'] ==
          'TYPESCRIPT_VERSION_MISMATCH',
    );
    compiler.deleteSync();
    result = await invoke(2);
    check(result['tool_versions']['typescript'] == null);
    check(
      result['payload']['tool_errors'][0]['code'] ==
          'TYPESCRIPT_ASSETS_UNAVAILABLE',
    );
  } finally {
    base.deleteSync(recursive: true);
  }
  stdout.writeln('$count real check process/schema checks passed.');
}
