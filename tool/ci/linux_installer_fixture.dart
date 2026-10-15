// Narrow privileged fixture operations within a newly created, token-owned root.
import 'dart:io';

import 'package:path/path.dart' as p;

const installerRootMarker = '.archway-installer-owner';

Future<void> main(List<String> arguments) async {
  try {
    if (arguments.length != 3)
      throw const FormatException('Expected root, token, operation');
    final root = Directory(arguments[0]);
    final token = arguments[1];
    if (!p.isAbsolute(root.path) ||
        p.normalize(root.path) != root.path ||
        !p.basename(root.path).startsWith('archway installer ') ||
        await root.resolveSymbolicLinks() != root.path ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(token)) {
      throw const FormatException('Invalid owned installer root');
    }
    final marker = File(p.join(root.path, installerRootMarker));
    if (await FileSystemEntity.type(marker.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await marker.readAsString() != token) {
      throw const FormatException('Invalid owned installer root');
    }
    switch (arguments[2]) {
      case 'foreign':
        for (final entry in {
          'system/usr/lib/archway/user-notes.txt': 'preserve foreign file',
          'system/home/user/project/architecture.yaml': 'preserve project',
        }.entries) {
          final file = File(p.join(root.path, entry.key));
          // Check each component before creation, including the destination.
          var path = root.path;
          for (final component in p.split(entry.key)) {
            path = p.join(path, component);
            final type = await FileSystemEntity.type(path, followLinks: false);
            if (type != FileSystemEntityType.notFound &&
                type != FileSystemEntityType.directory) {
              throw const FormatException(
                'Fixture destination is not fresh or has an alias',
              );
            }
          }
          await file.parent.create(recursive: true);
          await file.writeAsString(entry.value);
        }
      case 'cleanup':
        // Dart recursive deletion removes internal links themselves, never targets.
        await root.delete(recursive: true);
      default:
        throw const FormatException('Unknown installer fixture operation');
    }
  } catch (error) {
    stderr.writeln('Installer fixture failed: $error');
    exitCode = 1;
  }
}
