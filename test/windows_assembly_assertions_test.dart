import 'dart:io';

import 'package:test/test.dart';

import '../tool/ci/windows_assembly_assertions.dart';

void main() {
  test(
    'Windows assembly guards reject execution on a non-Windows host',
    () async {
      await expectLater(
        assertWindowsAssemblyGuards(
          Directory.current,
          'pwsh',
          File('dart'),
          Directory.current,
        ),
        throwsUnsupportedError,
      );
    },
    skip: Platform.isWindows ? 'Requires a non-Windows host.' : false,
  );
}
