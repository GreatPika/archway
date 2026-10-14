// Shared native release policy. Archive verification authenticates these identities.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import '../validation/json_values.dart';
import 'archive_input.dart';
import 'native_manifest.dart';
import 'strict_json.dart';

const nativeTargets = {
  'linux-x64': ('archway', 'libarchway_io.so'),
  'macos-arm64': ('archway', 'libarchway_io.dylib'),
  'windows-x64': ('archway.exe', 'archway_io.dll'),
};
const nativeSchemas = [
  'policy.schema.json',
  'public-result.schema.json',
  'export-diagnostics.schema.json',
];

void requireNative(bool value, String message) {
  if (!value) throw FormatException(message);
}

Future<Map<String, Object?>> readNativeJson(File file) => withArchiveInput(
  file,
  (input) async =>
      decodeEvidenceJson(await input.file.readAsString())
          as Map<String, Object?>,
  maxBytes: maxArchiveJsonBytes,
);

Future<YamlMap> nativePubspec(Directory source) => withArchiveInput(
  File(p.join(source.path, 'pubspec.yaml')),
  (input) async => loadYaml(await input.file.readAsString()) as YamlMap,
  maxBytes: maxArchiveJsonBytes,
);

/// Canonical version plus actual runtime identities, rather than wrapper metadata.
Future<Map<String, String>> nativeVersions(
  Directory source,
  String dart,
  String node,
) async {
  // Release runtimes are exact reviewed product pins; SDK compatibility alone
  // does not establish the compiler/runtime identity used for a release.
  requireNative(
    dart == '3.13.3' && node == '24.21.0',
    'Observed runtimes differ from release pins',
  );
  final pubspec = await nativePubspec(source);
  final version = pubspec['version'] as String;
  Version.parse(version);
  requireNative(
    VersionConstraint.parse(pubspec['environment']['sdk'] as String)
        .allows(Version.parse(dart)),
    'Build Dart is outside source SDK constraint',
  );
  Version.parse(node);
  final lock = await readNativeJson(
    File(p.join(source.path, 'assets', 'typescript', 'package-lock.json')),
  );
  final packages = lock['packages'] as Map;
  return {
    'archway': version,
    'dart': dart,
    'node': node,
    for (final name in ['typescript', 'yaml'])
      name: (packages['node_modules/$name'] as Map)['version'] as String,
  };
}

/// Tracked assembly assets have an independent source-byte oracle. Vendor bytes
/// are bound by the verified transport inventory and its actual assembly evidence.
Future<Map<String, ArchiveFileIdentity>> sourceNativeAssets(
  Directory source,
) async {
  final git = await Process.run(
    'git',
    [
      '-C',
      source.path,
      'ls-files',
      '-z',
      '--',
      'assets/typescript',
      'contracts/json',
      'LICENSE',
    ],
    environment: Map.of(Platform.environment)
      ..removeWhere((key, _) => key.toUpperCase().startsWith('GIT_')),
    includeParentEnvironment: false,
  );
  requireNative(git.exitCode == 0, 'Cannot enumerate tracked native inputs');
  final files = <String, ArchiveFileIdentity>{};
  for (final name
      in (git.stdout as String)
          .split('\x00')
          .where((name) => name.isNotEmpty)) {
    final parts = name.split('/');
    final owned =
        (parts.length == 3 &&
            name.startsWith('assets/typescript/') &&
            ['.cjs', '.json', '.md'].any(name.endsWith)) ||
        name.startsWith('assets/typescript/licenses/') ||
        name == 'LICENSE' ||
        nativeSchemas.any((schema) => name == 'contracts/json/$schema');
    if (!owned) continue;
    files[name] = await withArchiveInput(
      File(p.joinAll([source.path, ...name.split('/')])),
      (input) async => (size: input.size, mode: 0x1a4, sha256: input.sha256),
      maxBytes: maxArchiveFileBytes,
    );
  }
  for (final schema in nativeSchemas) {
    requireNative(
      files.containsKey('contracts/json/$schema'),
      'Missing tracked public schema: $schema',
    );
  }
  return files;
}

Future<void> validateNativePayload(
  Map<String, Object?> manifest,
  Directory source, {
  required String target,
  required String version,
  required Map<String, Object?> identity,
}) async {
  requireNative(
    nativeTargets.containsKey(target) &&
        manifest['schema_version'] == 1 &&
        manifest['version'] == version &&
        manifest['target'] == target &&
        sameJson(manifest['source'], identity),
    'Native source/version/target mismatch',
  );
  final versions = manifest['versions'] as Map;
  final expectedVersions = await nativeVersions(
    source,
    versions['dart'] as String,
    versions['node'] as String,
  );
  requireNative(
    expectedVersions['archway'] == version &&
        sameJson(versions, expectedVersions),
    'Native versions differ from source',
  );
  final parsed = parseNativeManifest(utf8.encode(jsonEncode(manifest)));
  final files = parsed.completeArchiveInventory.files;
  final (binary, bridge) = nativeTargets[target]!;
  final payloads = {'bin/$target/$binary', 'native/$target/$bridge'};
  final sourceFiles = await sourceNativeAssets(source);
  final expected = {
    ...payloads,
    'README.txt',
    'manifest.json',
    for (final name in sourceFiles.keys)
      name.startsWith('contracts/json/')
          ? 'schemas/${p.posix.basename(name)}'
          : name,
  };
  for (final name in payloads) {
    requireNative(
      files[name] != null && files[name]!.size > 0,
      'Missing or empty genuine native payload: $name',
    );
  }
  requireNative(
    target == 'windows-x64' || files['bin/$target/$binary']!.mode == 0x1ed,
    'Native executable lacks execute mode',
  );
  for (final name in [
    'licenses/pnpm-MIT.txt',
    'licenses/yaml-ISC.txt',
    'vendor/typescript/package.json',
    'vendor/typescript/lib/typescript.js',
    'vendor/typescript/lib/lib.es2022.d.ts',
    'vendor/typescript/LICENSE.txt',
    'vendor/yaml/package.json',
    'vendor/yaml/dist/index.js',
    'vendor/yaml/LICENSE',
  ]) {
    final file = files['assets/typescript/$name'];
    requireNative(
      file != null && file.size > 0,
      'Missing required native asset: $name',
    );
  }
  for (final entry in sourceFiles.entries) {
    final name = entry.key.startsWith('contracts/json/')
        ? 'schemas/${p.posix.basename(entry.key)}'
        : entry.key;
    final actual = files[name];
    requireNative(
      actual != null &&
          actual.size == entry.value.size &&
          actual.sha256 == entry.value.sha256,
      'Native asset differs from canonical source: $name',
    );
  }
  requireNative(
    files['README.txt'] != null && files['README.txt']!.size > 0,
    'Missing native guide',
  );
  for (final name in files.keys) {
    final vendor =
        name.startsWith('assets/typescript/vendor/typescript/') ||
        name.startsWith('assets/typescript/vendor/yaml/');
    requireNative(
      expected.contains(name) || vendor,
      'File outside native layout: $name',
    );
    final mode = files[name]!.mode;
    requireNative(
      (target == 'windows-x64' ? {0x1b6, 0x1ff, 0x1a4} : {0x1a4, 0x1ed})
          .contains(mode),
      'Invalid native permissions: $name',
    );
  }
}
