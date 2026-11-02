import 'package:test/test.dart';

import '../tool/ci/native_fixture_controls.dart';

void main() {
  test('Windows fixture controls accept uppercase ProgramFiles from Dart', () {
    expect(
      requiredFixtureEnvironment(
        {'PROGRAMFILES': r'C:\Program Files'},
        'ProgramFiles',
        windows: true,
      ),
      r'C:\Program Files',
    );
  });
  test('required fixture values fail clearly when absent or empty', () {
    for (final windows in [false, true]) {
      for (final environment in <Map<String, String>>[
        {},
        {'ProgramFiles': ''},
      ]) {
        expect(
          () => requiredFixtureEnvironment(
            environment,
            'ProgramFiles',
            windows: windows,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('ProgramFiles'),
            ),
          ),
        );
      }
    }
  });
  test(
    'Windows control keys use case-insensitive lookup without changing values',
    () {
      const environment = {
        'gItHuB_eNv': r'C:\runner space\environment',
        'runner_temp': r'D:\runner space\temp',
        'Path': r'C:\trusted node;C:\Windows\System32',
      };
      expect(
        requiredFixtureEnvironment(environment, 'GITHUB_ENV', windows: true),
        r'C:\runner space\environment',
      );
      expect(
        requiredFixtureEnvironment(environment, 'RUNNER_TEMP', windows: true),
        r'D:\runner space\temp',
      );
      expect(
        requiredFixtureEnvironment(environment, 'PATH', windows: true),
        r'C:\trusted node;C:\Windows\System32',
      );
    },
  );
  test('non-Windows environment keys remain case-sensitive', () {
    const environment = {'PATH': '/trusted/bin', 'Path': '/other/bin'};
    expect(
      requiredFixtureEnvironment(environment, 'PATH', windows: false),
      '/trusted/bin',
    );
    expect(
      requiredFixtureEnvironment(environment, 'Path', windows: false),
      '/other/bin',
    );
    expect(
      () => requiredFixtureEnvironment(environment, 'path', windows: false),
      throwsFormatException,
    );
  });
}
