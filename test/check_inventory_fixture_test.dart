import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/check_inventory_fixture.dart';
import 'support/native_process_support.dart';

void main() {
  test(
    'independent inventory preserves kinds and Unicode scalar order',
    () async {
      final node = Platform.environment['ARCHWAY_TEST_NODE'];
      if (node == null)
        throw StateError('ARCHWAY_TEST_NODE must name pinned Node');
      final root = Directory.systemTemp.createTempSync(
        'archway-inventory-test-',
      );
      try {
        final file = File(p.join(root.path, 'file'))
          ..writeAsStringSync('value');
        Directory(p.join(root.path, 'directory')).createSync();
        File(p.join(root.path, '\ue000')).writeAsStringSync('');
        File(p.join(root.path, '\u{10000}')).writeAsStringSync('');
        Link(p.join(root.path, 'link')).createSync(file.path);
        expect(await inventoryEntries(root.path, node), [
          ['directory', 'directory'],
          ['file', 'file'],
          ['link', 'symlink'],
          ['\ue000', 'file'],
          ['\u{10000}', 'file'],
        ]);
        if (Platform.isWindows) {
          final attributes = windowsInventoryAttributes(
            root.path,
            await inventoryEntries(root.path, node),
          );
          expect(attributes.every((e) => e['win32_error'] == null), isTrue);
          expect(
            windowsReparseMetadata(p.join(root.path, 'link')).tag,
            0xa000000c,
          );
          final junction = p.join(root.path, 'junction');
          final command = windowsInventoryCommand();
          expect(p.isAbsolute(command), isTrue);
          expect(File(command).existsSync(), isTrue);
          final created = await runNativeProcess([
            command,
            '/d',
            '/c',
            'mklink',
            '/J',
            junction,
            p.join(root.path, 'directory'),
          ], timeout: const Duration(seconds: 15));
          expect(created.exitCode, 0);
          expect(windowsReparseMetadata(junction).tag, 0xa0000003);
          expect(
            await inventoryEntries(root.path, node),
            contains(['junction', 'symlink']),
          );
          Link(junction).deleteSync();
        }
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
}
