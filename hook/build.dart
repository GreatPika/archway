import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final target = (
      input.config.code.targetOS,
      input.config.code.targetArchitecture,
    );
    final relative = switch (target) {
      (OS.linux, Architecture.x64) => 'native/linux-x64/libarchway_io.so',
      (OS.macOS, Architecture.arm64) =>
        'native/macos-arm64/libarchway_io.dylib',
      (OS.windows, Architecture.x64) => 'native/windows-x64/archway_io.dll',
      _ => throw UnsupportedError(
        'Archway supports Linux x64, macOS arm64, and Windows x64; got $target.',
      ),
    };
    final asset = input.packageRoot.resolve(relative);
    if (!await File(asset.toFilePath()).exists()) {
      throw StateError(
        'Bundled Archway native I/O asset is missing: $relative',
      );
    }
    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        name: 'src/native/native_io.dart',
        linkMode: DynamicLoadingBundled(),
        file: asset,
      ),
    );
    output.dependencies.add(asset);
  });
}
