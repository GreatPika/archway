// CLI regressions for realpath identity, persistent route changes and trace gaps.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../tool/validation/json_schema.dart';
import '../tool/validation/json_values.dart';
import 'support/installation_staging.dart';
import 'support/native_process_support.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2) {
    stderr.writeln(
      'Usage: dart run test/alias_trace_gap_process_smoke.dart <executable> <node>',
    );
    exitCode = 64;
    return;
  }
  final node = File(arguments[1]).resolveSymbolicLinksSync();
  final schema = ContractSchema(
    jsonDecode(
      File.fromUri(
        Platform.script.resolve('../contracts/json/public-result.schema.json'),
      ).readAsStringSync(),
    ),
  );
  final base = Directory(
    Directory.systemTemp
        .createTempSync('archway-trace-gap-')
        .resolveSymbolicLinksSync(),
  );
  try {
    final install = Directory(p.join(base.path, 'installation'))..createSync();
    final binary = stageInstallation(File(arguments[0]), install);
    final root = Directory(p.join(base.path, 'project'));
    File at(String name) => File(p.join(root.path, name));
    Directory(at('src/app').path).createSync(recursive: true);
    Directory(at('src/core').path).createSync();
    at('src/app/main.ts').writeAsStringSync("import '../core/private';");
    at('src/core/private.ts').writeAsStringSync('export {};');
    at('tsconfig.json').writeAsStringSync(
      '{"compilerOptions":{"target":"ES2022","module":"CommonJS"},"include":["src/**/*.ts"]}',
    );
    at('architecture.yaml').writeAsStringSync('''version: 1
projects: [{id: web, adapter: typescript, tsconfig: tsconfig.json}]
scope: [src/]
exclude: []
nodes:
  - {id: app, responsibility: App, owns: [src/app/], allows: [], public: []}
  - {id: core, responsibility: Core, owns: [src/core/], allows: [], public: []}
''');
    final helper = File(p.join(install.path, 'assets/typescript/helper.cjs'));
    final source = helper.readAsStringSync();
    const marker = 'const rootInput = evidence.observe(root);';
    _check(
      marker.allMatches(source).length == 1,
      'Expected one helper instrumentation marker',
    );
    String instrument(String code) =>
        source.replaceFirst(marker, '$code\n      $marker');
    Future<Map<String, dynamic>> check(int expected, {int seconds = 30}) async {
      final result = await runNativeProcess(
        [binary.path, '--root', root.path, 'check'],
        timeout: Duration(seconds: seconds),
        environment: {...Platform.environment, 'PATH': p.dirname(node)},
      );
      _check(result.exitCode == expected, 'Expected $expected: $result');
      _check(
        result.stderr.isEmpty &&
            result.stdout.where((b) => b == 10).length == 1,
        'Expected one JSON line and silent stderr: $result',
      );
      final value =
          jsonDecode(utf8.decode(result.stdout)) as Map<String, dynamic>;
      _check(
        schema.errors(value).isEmpty,
        'Invalid public schema: ${schema.errors(value)}',
      );
      return value['payload'] as Map<String, dynamic>;
    }

    Future<void> nodeScript(String script) async {
      final result = await runNativeProcess([
        node,
        '-e',
        script,
      ], timeout: const Duration(seconds: 15));
      _check(result.exitCode == 0, 'Native fixture setup failed: $result');
    }

    final compiler = p.join(
      helper.parent.path,
      'vendor/typescript/lib/typescript.js',
    );
    final swapped = String.fromCharCodes(
      compiler.codeUnits.map(
        (c) => c >= 65 && c <= 90
            ? c + 32
            : c >= 97 && c <= 122
            ? c - 32
            : c,
      ),
    );
    helper.writeAsStringSync(
      instrument(
        'for (const p of ${jsonEncode([compiler, swapped])}) { if (fs.existsSync(p)) { fs.realpathSync(p); fs.realpathSync.native(p); } }',
      ),
    );
    _check(
      (await check(1))['analysis_complete'] == true,
      'Realpath API baseline incomplete',
    );
    final realHelper = File(p.join(helper.parent.path, 'real-helper.cjs'));
    final probe = Directory(p.join(base.path, 'probe'))..createSync();
    final leaf = File(p.join(probe.path, 'same.json'))..writeAsStringSync('{}');
    realHelper.writeAsStringSync(
      instrument('fs.statSync(${jsonEncode(leaf.path)});'),
    );
    for (final (move, target, type) in [
      (leaf.path, p.join(base.path, 'same.json'), 'file'),
      (probe.path, p.join(base.path, 'moved-probe'), 'dir'),
    ]) {
      helper.writeAsStringSync(
        "const fs=require('node:fs'), native=fs.realpathSync.native;let first=true;fs.realpathSync.native=function(file,...args){if(first && String(file)===${jsonEncode(leaf.path)}){first=false;fs.renameSync(${jsonEncode(move)},${jsonEncode(target)});fs.symlinkSync(${jsonEncode(target)},${jsonEncode(move)},${jsonEncode(type)});}return native(file,...args);};require('./real-helper.cjs');",
      );
      final report = await check(2);
      _check(
        FileSystemEntity.isLinkSync(move),
        'Persistent-link injection did not execute',
      );
      _check(
        _has(report['tool_errors'], 'TYPESCRIPT_INPUT_TRACE_FAILED'),
        'Missing trace failure: $report',
      );
      _violation(report);
      Link(move).deleteSync();
      if (type == 'dir') {
        Directory(target).renameSync(move);
      } else {
        File(target).renameSync(move);
      }
    }
    final alias = Link(p.join(base.path, 'through'));
    final via = Link(p.join(base.path, 'via'));
    // Real directory symlinks, not Dart's Windows junction normalization.
    await nodeScript(
      "const fs=require('node:fs');fs.symlinkSync(${jsonEncode(probe.path)},${jsonEncode(alias.path)},'dir');fs.symlinkSync(${jsonEncode(probe.path)},${jsonEncode(via.path)},'dir');",
    );
    _check(
      Directory(alias.path).existsSync() && Directory(via.path).existsSync(),
      'Directory aliases are not traversable',
    );
    final observed = p.join(alias.path, 'same.json');
    realHelper.writeAsStringSync(
      instrument('fs.statSync(${jsonEncode(observed)});'),
    );
    helper.writeAsStringSync(
      "const fs=require('node:fs'), native=fs.realpathSync.native;let first=true;fs.realpathSync.native=function(file,...args){if(first && String(file)===${jsonEncode(observed)}){first=false;fs.unlinkSync(${jsonEncode(alias.path)});fs.symlinkSync(${jsonEncode(via.path)},${jsonEncode(alias.path)},'dir');}return native(file,...args);};require('./real-helper.cjs');",
    );
    final report = await check(2);
    String normalized(String path) {
      if (!Platform.isWindows) return path;
      if (path.startsWith('\\\\?\\')) path = path.substring(4);
      return path.replaceAll('/', '\\').toLowerCase();
    }

    _check(
      normalized(alias.targetSync()) == normalized(via.path),
      'Intermediate-hop injection did not execute',
    );
    _check(
      _has(report['unknowns'], 'INPUT_CHANGED') &&
          report['analysis_complete'] == false,
      'Intermediate hop change not detected: $report',
    );
    helper.writeAsStringSync(
      instrument(
        'try { fs.readFileSync(${jsonEncode(p.join(base.path, 'optional.json'))}); } catch {}',
      ),
    );
    File(p.join(base.path, 'exists')).writeAsStringSync('exists');
    File(p.join(base.path, 'regular')).writeAsStringSync('regular');
    for (final target in [
      'missing.json',
      'missing\udcff.json',
      'missing/../exists',
      'regular/../exists',
    ]) {
      final optional = File(p.join(base.path, 'optional.json'));
      if (Platform.isWindows) {
        final nativeTarget = target.replaceAll('/', '\\');
        _windowsRawLink(optional.path, nativeTarget);
        _check(
          _readWindowsRawLink(optional.path) == nativeTarget,
          'Raw UTF-16 target changed',
        );
      } else {
        // Preserve the original invalid UTF-8 byte, not U+FFFD replacement.
        final bytes = [
          for (final code in target.codeUnits)
            if (code == 0xdcff) 0xff else code,
        ];
        await nodeScript(
          "const fs=require('node:fs');const target=Buffer.from(${jsonEncode(bytes)});fs.symlinkSync(target,${jsonEncode(optional.path)});if(!fs.readlinkSync(${jsonEncode(optional.path)},{encoding:'buffer'}).equals(target))throw Error('Raw UTF-8 target changed');",
        );
      }
      final readable =
          Platform.isWindows &&
          (target == 'missing/../exists' || target == 'regular/../exists');
      if (readable) {
        _check(
          optional.readAsStringSync() == 'exists',
          'Windows dot-target bytes',
        );
        _check(
          optional.resolveSymbolicLinksSync() == p.join(base.path, 'exists'),
          'Windows dot-target identity',
        );
      } else {
        var failed = false;
        try {
          optional.readAsBytesSync();
        } on FileSystemException {
          failed = true;
        }
        _check(
          failed,
          'Expected unreadable alias target: ${jsonEncode(target)}',
        );
      }
      final report = await check(readable ? 1 : 2, seconds: 20);
      if (readable) {
        final identity = report['input_identity'];
        _check(
          report['analysis_complete'] == true &&
              (report['tool_errors'] as List).isEmpty,
          'Windows dot walk incomplete',
        );
        _check(
          identity['rechecked'] == true &&
              (identity['changed_inputs'] as List).isEmpty,
          'Windows dot walk changed',
        );
        _check(
          (identity['inputs'] as List).any(
            (entry) => sameJson(entry, {
              'kind': 'resolution',
              'location': {
                'kind': 'external',
                'canonical_file_uri': File(p.join(base.path, 'exists')).uri
                    .toString(),
              },
              'presence': 'present',
              'hash': 'sha256:${sha256.convert(utf8.encode('exists'))}',
            }),
          ),
          'Missing Windows dot-target input',
        );
        _check(
          (identity['aliases'] as List).any(
            (entry) => sameJson(entry, {
              'observed_file_uri': optional.uri.toString(),
              'canonical_file_uri': File(p.join(base.path, 'exists')).uri
                  .toString(),
            }),
          ),
          'Missing Windows dot-target alias',
        );
      } else {
        _check(
          report['analysis_complete'] == false &&
              _has(report['tool_errors'], 'TYPESCRIPT_INPUT_TRACE_FAILED'),
          'Caught unreadable alias lost trace failure: $report',
        );
      }
      _violation(report);
      Link(optional.path).deleteSync();
    }
  } finally {
    base.deleteSync(recursive: true);
  }
  stdout.writeln(
    '8 realpath API, persistent-hop and caught-read alias trace-gap checks passed',
  );
}

bool _has(dynamic entries, String code) =>
    (entries as List).any((entry) => entry['code'] == code);
void _violation(Map<String, dynamic> report) => _check(
  (report['facts']['edges'] as List).isNotEmpty &&
      report['violations'][0]['code'] == 'DEPENDENCY_NOT_ALLOWED',
  'Independent violation lost: $report',
);
void _check(bool valid, String message) {
  if (!valid) throw StateError(message);
}

// Dart/Node UTF-8 path conversions cannot carry an unpaired native UTF-16 unit.
// These fixture-only Win32 calls preserve and verify the Python surrogateescape
// case without changing the target or weakening the malformed-encoding probe.
void _windowsRawLink(String path, String target) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  final create = kernel
      .lookupFunction<
        Uint8 Function(Pointer<Utf16>, Pointer<Utf16>, Uint32),
        int Function(Pointer<Utf16>, Pointer<Utf16>, int)
      >('CreateSymbolicLinkW');
  final error = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  using((arena) {
    final name = path.toNativeUtf16(allocator: arena);
    final value = target.toNativeUtf16(allocator: arena);
    var result = create(name, value, 2);
    var code = result == 0 ? error() : 0;
    if (result == 0 && code == 87) {
      result = create(name, value, 0);
      code = result == 0 ? error() : 0;
    }
    _check(result != 0, 'Create raw Windows alias: $code');
  });
}

String _readWindowsRawLink(String path) {
  final kernel = DynamicLibrary.open('kernel32.dll');
  // Resolve every function before a fallible call can set thread last-error.
  final lastError = kernel.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
  );
  final open = kernel
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Utf16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Utf16>,
          int,
          int,
          Pointer<Void>,
          int,
          int,
          Pointer<Void>,
        )
      >('CreateFileW');
  final query = kernel
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint32,
          Pointer<Void>,
          Uint32,
          Pointer<Uint8>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Void>,
          int,
          Pointer<Void>,
          int,
          Pointer<Uint8>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
        )
      >('DeviceIoControl');
  final close = kernel
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  return using((arena) {
    final nativePath = path.toNativeUtf16(allocator: arena);
    final bytes = arena<Uint8>(16384); // MAXIMUM_REPARSE_DATA_BUFFER_SIZE.
    final count = arena<Uint32>();
    // OPEN_EXISTING, BACKUP_SEMANTICS | OPEN_REPARSE_POINT; no target follow.
    final handle = open(nativePath, 0, 7, nullptr, 3, 0x02200000, nullptr);
    if (handle.address == -1 || handle.address == 0xffffffffffffffff) {
      final code = lastError();
      throw FileSystemException(
        'Open fixture reparse point',
        path,
        OSError('Win32', code),
      );
    }
    OSError? failure;
    var operation = 'Read fixture reparse point';
    try {
      // FSCTL_GET_REPARSE_POINT; no reparse data is ever written by this copier.
      if (query(handle, 0x900a8, nullptr, 0, bytes, 16384, count, nullptr) ==
          0) {
        failure = OSError('Win32', lastError());
      }
    } finally {
      // Consume this handle once, and retain a primary query error if present.
      if (close(handle) == 0) {
        final code = lastError();
        if (failure == null) {
          operation = 'Close fixture reparse point';
          failure = OSError('Win32', code);
        }
      }
    }
    if (failure != null) throw FileSystemException(operation, path, failure);
    if (count.value < 8 || count.value > 16384) {
      throw FileSystemException('Invalid reparse buffer size', path);
    }
    final data = ByteData.sublistView(bytes.asTypedList(count.value));
    final tag = data.getUint32(0, Endian.little);
    final end = 8 + data.getUint16(4, Endian.little);
    if (tag != 0xa000000c || end < 20 || end > data.lengthInBytes) {
      throw FileSystemException('Invalid symbolic-link reparse data', path);
    }
    // SymbolicLinkReparseBuffer.PathBuffer starts at byte 20. Offsets are bytes.
    final offset = data.getUint16(8, Endian.little);
    final length = data.getUint16(10, Endian.little);
    if (offset.isOdd || length.isOdd || 20 + offset + length > end) {
      throw FileSystemException('Invalid substitute-name extent', path);
    }
    return String.fromCharCodes([
      for (var i = 0; i < length; i += 2)
        data.getUint16(20 + offset + i, Endian.little),
    ]);
  });
}
