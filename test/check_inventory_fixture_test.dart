import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/check_inventory_fixture.dart';
import 'support/native_process_support.dart';
import 'support/windows_process.dart';

Matcher containsInventoryEntry(String name, String kind) =>
    contains(equals([name, kind]));

void main() {
  test('inventory entry matcher compares both nested row values', () {
    final matcher = containsInventoryEntry('junction', 'symlink');
    expect([
      ['junction', 'symlink'],
    ], matcher);
    expect([
      ['junction', 'directory'],
    ], isNot(matcher));
    expect([
      ['other', 'symlink'],
    ], isNot(matcher));
    expect([
      ['symlink', 'junction'],
    ], isNot(matcher));
  });

  test('junction launch encodes PowerShell literals as UTF-16LE argv', () {
    final arguments = windowsInventoryJunctionArguments(
      r"C:\fixture café 𐀀\owner's alias",
      r"C:\fixture café 𐀀\target & $name",
    );
    expect(arguments.take(3), [
      '-NoProfile',
      '-NonInteractive',
      '-EncodedCommand',
    ]);
    expect(arguments, hasLength(4));
    final bytes = ByteData.sublistView(base64Decode(arguments.last));
    final script = String.fromCharCodes([
      for (var i = 0; i < bytes.lengthInBytes; i += 2)
        bytes.getUint16(i, Endian.little),
    ]);
    expect(
      script,
      contains(
        r"New-Item -ItemType Junction -Path 'C:\fixture café 𐀀\owner''s alias' -Target 'C:\fixture café 𐀀\target & $name' -ErrorAction Stop | Out-Null",
      ),
    );
    expect(script, contains('exit 0'));
    expect(script, contains('exit 1'));
    const executable =
        r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe';
    expect(
      windowsCommandLine([executable, ...arguments]),
      '"$executable" "-NoProfile" "-NonInteractive" "-EncodedCommand" "${arguments.last}"',
    );
  });

  test(
    'native junction launch preserves spaces, Unicode and apostrophes',
    () async {
      final root = Directory.systemTemp.createTempSync(
        "archway junction café owner's ",
      );
      final junction = p.join(root.path, "alias café owner's");
      try {
        final target = Directory(p.join(root.path, "target café owner's"))
          ..createSync();
        final command = windowsInventoryCommand();
        expect(p.windows.isAbsolute(command), isTrue);
        expect(p.windows.basename(command), 'powershell.exe');
        final created = await runNativeProcess([
          command,
          ...windowsInventoryJunctionArguments(junction, target.path),
        ], timeout: const Duration(seconds: 15));
        expect(
          created.exitCode,
          0,
          reason: utf8.decode(created.stderr, allowMalformed: true),
        );
        final metadata = windowsReparseMetadata(junction);
        expect(metadata.attributes & 0x400, isNonZero);
        expect(metadata.tag, 0xa0000003);
        expect(
          Directory(junction).resolveSymbolicLinksSync(),
          target.resolveSymbolicLinksSync(),
        );
      } finally {
        if (FileSystemEntity.typeSync(junction, followLinks: false) !=
            FileSystemEntityType.notFound) {
          Link(junction).deleteSync();
        }
        root.deleteSync(recursive: true);
      }
    },
    skip: !Platform.isWindows
        ? 'Requires native Windows junction creation.'
        : false,
  );

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
            ...windowsInventoryJunctionArguments(
              junction,
              p.join(root.path, 'directory'),
            ),
          ], timeout: const Duration(seconds: 15));
          expect(
            created.exitCode,
            0,
            reason: utf8.decode(created.stderr, allowMalformed: true),
          );
          expect(windowsReparseMetadata(junction).tag, 0xa0000003);
          expect(
            await inventoryEntries(root.path, node),
            containsInventoryEntry('junction', 'symlink'),
          );
          Link(junction).deleteSync();
        }
      } finally {
        root.deleteSync(recursive: true);
      }
    },
  );
}
