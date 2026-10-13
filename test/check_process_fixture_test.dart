import 'package:test/test.dart';

import 'check_process_smoke.dart' show wildcardTargetUri;

void main() {
  test(
    'malformed helper target retains literal wildcard on all path styles',
    () {
      expect(
        () => Uri.file(r'C:\project\src\core\bad*.ts', windows: true),
        throwsArgumentError,
      );
      for (final (directory, expected) in [
        (
          Uri.directory(r'C:\project with spaces\café\src\core', windows: true),
          'file:///C:/project%20with%20spaces/caf%C3%A9/src/core/bad*.ts',
        ),
        (
          Uri.directory(
            r'\\server\share\project with spaces\src\core',
            windows: true,
          ),
          'file://server/share/project%20with%20spaces/src/core/bad*.ts',
        ),
        (
          Uri.directory('/project with spaces/café/src/core', windows: false),
          'file:///project%20with%20spaces/caf%C3%A9/src/core/bad*.ts',
        ),
      ]) {
        expect(wildcardTargetUri(directory), expected);
        expect(
          Uri.parse(wildcardTargetUri(directory)).pathSegments.last,
          'bad*.ts',
        );
      }
    },
  );
}
