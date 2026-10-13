// Independent ABI wire failures observed through the real compiled CLI.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'support/installation_staging.dart';
import 'support/native_process_support.dart';

void check(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError(
      'Usage: dart test/native_abi_process_smoke.dart <executable>',
    );
  }
  final temporary = Directory.systemTemp.createTempSync('archway-abi-');
  try {
    // Keep host TMPDIR aliases outside the deliberately failing alias oracle.
    final base = Directory(temporary.resolveSymbolicLinksSync());
    final binary = stageInstallation(
      File(arguments.single),
      Directory(p.join(base.path, 'bundle')),
    );
    final root = Directory(p.join(base.path, 'project'))..createSync();
    File(p.join(root.path, 'architecture.yaml')).writeAsStringSync(
      'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
    );
    final source = File(p.join(base.path, 'bridge.c'));
    final target = nativeTarget();
    final asset = File(
      p.join(base.path, 'bundle', 'native', target.target, target.library),
    );
    var count = 0;
    Future<void> invoke({
      String wire = '0,183,131074',
      String expected = 'EXPORT_TARGET_EXISTS',
      required String message,
      String flush = '0,0,0',
      String close = '0,0,0',
    }) async {
      var text = oracle.replaceAll('0,183,131074', wire);
      for (final operation in {'flush': flush, 'close': close}.entries) {
        text = text.replaceAll(
          'archway_io_${operation.key}(uint64_t h) { (void)h; return (result){0,0,0}',
          'archway_io_${operation.key}(uint64_t h) { (void)h; return (result){${operation.value}}',
        );
      }
      source.writeAsStringSync(text);
      await buildNativeLibrary(source, asset);
      final result = await runNativeProcess([
        binary.path,
        '--root',
        root.path,
        'export',
        '--format',
        'mermaid',
        '--out',
        'out.mmd',
      ], timeout: const Duration(seconds: 10));
      check(
        result.exitCode == 2 && result.stdout.isEmpty,
        'Export process: $result',
      );
      final diagnostic =
          (jsonDecode(utf8.decode(result.stderr))['diagnostics'] as List).last
              as Map;
      check(diagnostic['code'] == expected, 'Export diagnostic: $diagnostic');
      check(
        (diagnostic['message'] as String).contains(message),
        'Export message: $diagnostic',
      );
      check(
        !File(p.join(root.path, 'out.mmd')).existsSync(),
        'Export unexpectedly created output',
      );
      count++;
    }

    await invoke(message: 'win32 183');
    await invoke(
      wire: '0,3221225506,196614',
      expected: 'EXPORT_WRITE_FAILED',
      message: 'ntstatus 3221225506',
    );
    for (final wire in [
      '0,0,7', // Unknown category.
      '0,1,262150', // Unknown native domain.
      '0,1,65536', // Success cannot carry an error/domain.
      '1,183,131074', // A failed open cannot transfer a handle.
      '0,183,2', // Domain none cannot carry native error bits.
      '0,0,65542', // Native failure requires an actual native code.
    ]) {
      await invoke(
        wire: wire,
        expected: 'EXPORT_WRITE_FAILED',
        message: 'Invalid native I/O result encoding',
      );
    }
    await invoke(
      wire: '1,0,0',
      expected: 'EXPORT_WRITE_FAILED',
      message: 'Invalid native flush result',
      flush: '1,0,0',
    );
    await invoke(
      wire: '1,0,0',
      expected: 'EXPORT_WRITE_FAILED',
      message: 'Invalid native close result',
      close: '1,0,0',
    );
    // Real directory alias; the generated C oracle always reports exhaustion.
    final alias = Link(p.join(base.path, 'root-alias'))..createSync(root.path);
    final result = await runNativeProcess([
      binary.path,
      '--root',
      alias.path,
      'validate',
    ], timeout: const Duration(seconds: 10));
    check(
      result.exitCode == 2 && result.stderr.isEmpty,
      'Alias process: $result',
    );
    final diagnostic =
        (jsonDecode(utf8.decode(result.stdout))['diagnostics'] as List).first
            as Map;
    check(
      diagnostic['code'] == 'ROOT_ACCESS_FAILED',
      'Alias diagnostic: $diagnostic',
    );
    check(
      (diagnostic['message'] as String).contains(
        'Symbolic link target exceeds limit',
      ),
      'Alias message: $diagnostic',
    );
    count++;
    check(count == 11, 'Incomplete ABI scenario inventory: $count');
    stdout.writeln(
      '$count ABI v2 encoding/category/domain/buffer CLI cases passed',
    );
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

// Deliberately independent declarations and raw wire values, not io.h constants.
// A valid zero root handle must survive until the Win32 conflict is classified.
const oracle = r'''
#include <stdint.h>
#include <stdlib.h>
#ifdef _WIN32
#define API __declspec(dllexport)
#else
#define API
#endif
typedef struct { uint64_t value; uint32_t native_error; uint32_t status; } result;
API int32_t archway_io_version(void) { return 2; }
API void *archway_io_alloc(uint64_t size) { return malloc(size); }
API void archway_io_free(void *p) { free(p); }
API result archway_io_open_root(const char *p) { (void)p; return (result){0,0,0}; }
API result archway_io_open_child_directory(uint64_t p, const char *n) { (void)p; (void)n; return (result){0,0,0}; }
API result archway_io_open_output(uint64_t p, const char *n, uint32_t m) { (void)p; (void)n; (void)m; return (result){0,183,131074}; }
API result archway_io_observe_child(uint64_t p, const char *n) { (void)p; (void)n; return (result){1,0,0}; }
API result archway_io_write(uint64_t h, const void *b, uint64_t n) { (void)h; (void)b; return (result){n,0,0}; }
API result archway_io_flush(uint64_t h) { (void)h; return (result){0,0,0}; }
API result archway_io_close(uint64_t h) { (void)h; return (result){0,0,0}; }
API result archway_io_read_alias(const char *p, void *b, uint64_t n) { (void)p; (void)b; (void)n; return (result){0,0,4}; }
''';
