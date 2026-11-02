// Reviewed official fixture releases, retrieved 2026-11-02.
const fixtureDartVersion = '3.13.5';
const fixtureFlutterVersion = '3.47.7';
const fixtureGitUrl = 'https://github.com/dart-lang/core.git';
const fixtureGitRef = '4d80610a878cdb3f9f10e6a16a2af6631251a3c6';
const fixtureCollectionVersion = '1.19.1';
const fixtureFlutterPins = <String, ({String archive, String sha256})>{
  'linux-x64': (
    archive: 'stable/linux/flutter_linux_3.47.7-stable.tar.xz',
    sha256: 'af7455f540df951184c7953fbe3cf884766e7541dacf8571f9f582db03dd6230',
  ),
  'macos-arm64': (
    archive: 'stable/macos/flutter_macos_arm64_3.47.7-stable.zip',
    sha256: 'dd9da574c3168460550117eb0e8dd0313ae934fabf64a82a6d557fff5fd1422e',
  ),
  'windows-x64': (
    archive: 'stable/windows/flutter_windows_3.47.7-stable.zip',
    sha256: 'c2c875da25a1a1448d18ee4e8f398b2f6fce888b4775d8f9130538e16d826cb4',
  ),
};
