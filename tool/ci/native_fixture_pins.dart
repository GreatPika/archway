// Reviewed official fixture releases, retrieved 2026-10-12.
const fixtureDartVersion = '3.13.3';
const fixtureFlutterVersion = '3.47.4';
const fixtureWrongNodeVersion = '24.19.0';
const fixtureGitUrl = 'https://github.com/dart-lang/core.git';
const fixtureGitRef = '4d80610a878cdb3f9f10e6a16a2af6631251a3c6';
const fixtureCollectionVersion = '1.19.1';
const fixtureFlutterPins = <String, ({String archive, String sha256})>{
  'linux-x64': (
    archive: 'stable/linux/flutter_linux_3.47.4-stable.tar.xz',
    sha256: '5b45f0ceda99b9bebdc873e7e69f6450aeb4c30f454b505e2e62fc9255a907d3',
  ),
  'macos-arm64': (
    archive: 'stable/macos/flutter_macos_arm64_3.47.4-stable.zip',
    sha256: 'c6af6fa1d64946167b8637ba4c5a7bb3b8574729a1ebe931decd4924dbab7061',
  ),
  'windows-x64': (
    archive: 'stable/windows/flutter_windows_3.47.4-stable.zip',
    sha256: '31173300481bd06e377fd55ee84214689648b1817563efd7b450b7b78bdf351a',
  ),
};
const fixtureWrongNodePins = <String, ({String archive, String sha256})>{
  'linux-x64': (
    archive: 'linux-x64.tar.gz',
    sha256: 'f625d97cd707df4ff96254916fbc5ff014f09c09effe5a1e0ca8f6d41a8789d4',
  ),
  'macos-arm64': (
    archive: 'darwin-arm64.tar.gz',
    sha256: '8294b7aa9b03997481c06babf1e8b270c859358f27da57a11509afe537ac381d',
  ),
  'windows-x64': (
    archive: 'win-x64.zip',
    sha256: '57f71ab3652e797d84acddc79c81cc9ff1c6ddb2a1974cdb83f00fee9bff4c73',
  ),
};
