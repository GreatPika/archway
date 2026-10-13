import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

/// Private installation addressing; never consults the inspected repository.
/// Validation here uses dart:io directly so loading the bridge cannot recurse
/// through PhysicalPaths. Consumers still validate immediately before use.
class InstallationLayout {
  final Directory root;
  InstallationLayout._(this.root);

  static Future<InstallationLayout> resolve() async {
    // Only the maintainer assembler selects native mode. Product/JIT/snapshot
    // optimization modes say nothing about where this package is installed.
    if (const bool.fromEnvironment('archway.native')) {
      final target = Platform.isLinux && Abi.current() == Abi.linuxX64
          ? 'linux-x64'
          : Platform.isMacOS && Abi.current() == Abi.macosArm64
          ? 'macos-arm64'
          : Platform.isWindows && Abi.current() == Abi.windowsX64
          ? 'windows-x64'
          : null;
      if (target == null) {
        throw UnsupportedError(
          'Native installation requires Linux x64, macOS arm64 or Windows x64.',
        );
      }
      final executable = File(Platform.resolvedExecutable);
      requireOrdinaryFile(executable.path);
      final root = executable.parent.parent.parent;
      final binary = Platform.isWindows ? 'archway.exe' : 'archway';
      if (root.uri.resolve('bin/$target/$binary').toFilePath() !=
          executable.path) {
        throw UnsupportedError(
          'Native executable is outside the fixed installation layout.',
        );
      }
      return InstallationLayout._(root);
    }
    final source = await Isolate.resolvePackageUri(
      Uri.parse('package:archway/src/installation_layout.dart'),
    );
    if (source == null || source.scheme != 'file') {
      throw UnsupportedError(
        'Cannot resolve the Archway package installation.',
      );
    }
    final root = File.fromUri(source).parent.parent.parent;
    if (root.resolveSymbolicLinksSync() != root.path) {
      throw UnsupportedError('Archway installation is aliased.');
    }
    return InstallationLayout._(root);
  }

  String get typescriptAssets =>
      root.uri.resolve('assets/typescript').toFilePath();
  String get linuxBridge =>
      root.uri.resolve('native/linux-x64/libarchway_io.so').toFilePath();

  String get windowsBridge =>
      root.uri.resolve('native/windows-x64/archway_io.dll').toFilePath();

  String get macosBridge =>
      root.uri.resolve('native/macos-arm64/libarchway_io.dylib').toFilePath();

  static void requireOrdinaryFile(String path) {
    if (FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file ||
        File(path).resolveSymbolicLinksSync() != path) {
      throw UnsupportedError('Installation asset is missing or aliased: $path');
    }
  }
}
