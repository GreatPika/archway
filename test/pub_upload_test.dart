import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:tar/tar.dart';
import 'package:test/test.dart';

import '../tool/pub/upload.dart';
import '../tool/release/archive_input.dart';

void main() {
  late Directory root;
  late File archive;
  final bytes = [1, 2, 3];
  final files = ArchiveInventory({
    'a/file': (size: 3, mode: 420, sha256: sha256.convert(bytes).toString()),
  });
  setUp(() async {
    root = Directory(
      Directory.systemTemp
          .createTempSync('pub upload owner-')
          .resolveSymbolicLinksSync(),
    );
    archive = File(p.join(root.path, 'upload.tar.gz'));
    await Stream<TarEntry>.fromIterable([
      TarEntry.data(
        TarHeader(name: 'a', mode: 493, typeFlag: TypeFlag.dir),
        [],
      ),
      TarEntry.data(TarHeader(name: 'a/file', mode: 420), bytes),
    ]).transform(tarWriter).transform(gzip.encoder).pipe(archive.openWrite());
  });
  tearDown(() => root.deleteSync(recursive: true));
  test(
    'upload owner binds compressed pins and publishes measured exact bytes',
    () async {
      final expected = (
        size: archive.lengthSync(),
        sha256: sha256.convert(archive.readAsBytesSync()).toString(),
      );
      final output = Directory(p.join(root.path, 'output'));
      final result = await inspectPubUpload(
        archive,
        files,
        expected: expected,
        publishTo: output,
      );
      expect(result, {
        'size': expected.size,
        'sha256': expected.sha256,
        'unpacked_bytes': 3,
        'files': 1,
      });
      expect(File(p.join(output.path, 'a/file')).readAsBytesSync(), bytes);
      await expectLater(
        inspectPubUpload(
          archive,
          files,
          expected: (size: expected.size, sha256: '0' * 64),
          publishTo: Directory(p.join(root.path, 'bad')),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'diagnostic',
            contains('pinned identity'),
          ),
        ),
      );
      expect(Directory(p.join(root.path, 'bad')).existsSync(), isFalse);
    },
  );
  test('candidate compressed budget refuses a sparse oversized file before decoding', () async {
    final handle = archive.openSync(mode: FileMode.write);
    handle.truncateSync(100000000);
    handle.closeSync();
    await expectLater(
      inspectPubUpload(archive, files),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'diagnostic',
          contains('Archive input exceeds bound'),
        ),
      ),
    );
  });
}
