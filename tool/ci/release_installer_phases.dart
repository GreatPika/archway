// Bind original build/lifecycle commands to the verified native archive proof.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../validation/json_values.dart';
import 'release_execution_receipts.dart';

/// Called after native acceptance and installer record/log validation.
void validateInstallerPhases(
  Map<String, dynamic> proof,
  Directory directory,
  p.Context paths, {
  required String version,
}) {
  final receipt = proof['installer'] as Map;
  final records = receipt['commands'] as List;
  final acceptance = proof['acceptance'] as Map;
  final source = acceptance['source_root'] as String;
  final sdk = acceptance['fixtures']['manifest']['dart_sdk'] as String;
  final target = proof['target'];
  final dart = paths.join(
    sdk,
    'bin',
    target == 'windows-x64' ? 'dart.exe' : 'dart',
  );
  final bundle = proof['relocation']['executed'] as String;
  final artifact = paths.join(
    paths.dirname(acceptance['output_root'] as String),
    'installer',
    receipt['artifact']['name'] as String,
  );
  bool path(Object? a, String b) =>
      a is String && sameEvidencePath(a, b, paths);
  List<String> args(int index) =>
      (records[index]['arguments'] as List).cast<String>();
  int find(bool Function(List<String>) predicate, [int after = -1]) {
    for (var index = after + 1; index < records.length; index++) {
      if (records[index]['exit'] == 0 && predicate(args(index))) return index;
    }
    throw const FormatException(
      'Native installer required build/lifecycle phase is missing or reordered',
    );
  }

  void continuous(int start, int end, bool Function(List<String>) resets) {
    for (var index = start + 1; index < end; index++) {
      if (resets(args(index))) {
        throw const FormatException(
          'Native installer upgrade was interrupted by an uninstall/reset',
        );
      }
    }
  }

  bool builder(List<String> a, String owner, int length) =>
      a.length == length &&
      path(a[0], dart) &&
      path(a[1], paths.join(source, 'tool/installers', owner));
  void digestLine(int index, String digest, String name) {
    final record = records[index] as Map;
    final bytes = verifiedBytes(
      File(p.join(directory.path, record['stdout'] as String)),
      record['stdout_sha256'],
    );
    final expected = utf8.encode('$digest  $name');
    var start = 0, matched = false;
    for (var end = 0; end <= bytes.length; end++) {
      if (end != bytes.length && bytes[end] != 10 && bytes[end] != 13) continue;
      if (sameJson(bytes.sublist(start, end), expected)) matched = true;
      start = end + 1;
    }
    if (!matched) {
      throw const FormatException(
        'Native builder log does not bind expected artifact bytes and path',
      );
    }
  }

  if (target == 'linux-x64') {
    bool deb(List<String> a, bool finalBuild) =>
        builder(a, 'linux/build.dart', 8) &&
        a[2] == '--bundle' &&
        sameJson(a.sublist(4, 7), [
          '--expected-commit',
          proof['source']['commit'],
          '--output',
        ]) &&
        path(a[3], bundle) == finalBuild &&
        (finalBuild
            ? path(a[7], artifact)
            : paths.basename(a[7]) == 'test-only-old.deb');
    final old = find((a) => deb(a, false));
    final built = find((a) => deb(a, true), old);
    final oldArtifact = args(old)[7];
    digestLine(
      old,
      receipt['old_fixture']['artifact_sha256'] as String,
      paths.basename(oldArtifact),
    );
    digestLine(
      built,
      receipt['artifact']['sha256'] as String,
      paths.basename(artifact),
    );
    bool dpkg(List<String> a, String action, String operand) =>
        a.length == 8 &&
        sameJson(a.take(3).toList(), ['sudo', '-n', 'dpkg']) &&
        a[3].startsWith('--root=') &&
        a[4].startsWith('--log=') &&
        sameJson(a.sublist(5, 7), ['--force-script-chrootless', action]) &&
        path(a[7], operand);
    final installed = find((a) => dpkg(a, '--install', oldArtifact), built);
    final prefix = args(installed).take(6).toList();
    final upgraded = find(
      (a) =>
          dpkg(a, '--install', artifact) &&
          sameJson(a.take(6).toList(), prefix),
      installed,
    );
    continuous(
      installed,
      upgraded,
      (a) =>
          a.length == 8 &&
          sameJson(a.take(3).toList(), prefix.take(3).toList()) &&
          a[3].startsWith('--root=') &&
          path(a[3].substring(7), prefix[3].substring(7)) &&
          ['--remove', '--purge'].contains(a[6]) &&
          a[7] == 'archway',
    );
    find(
      (a) =>
          dpkg(a, '--remove', 'archway') &&
          sameJson(a.take(6).toList(), prefix),
      upgraded,
    );
  } else if (target == 'macos-arm64') {
    bool pkg(List<String> a, bool finalBuild) =>
        builder(a, 'macos/build.dart', 6) &&
        a[2] == '--bundle' &&
        a[4] == '--output' &&
        path(a[3], bundle) == finalBuild;
    final old = find((a) => pkg(a, false));
    final built = find((a) => pkg(a, true), old);
    String package(int index, String version) =>
        paths.join(args(index)[5], 'archway-$version-macos-arm64-unsigned.pkg');
    final oldArtifact = package(old, '0.0.0');
    digestLine(
      old,
      receipt['old_fixture']['artifact_sha256'] as String,
      oldArtifact,
    );
    digestLine(
      built,
      receipt['artifact']['sha256'] as String,
      package(built, version),
    );
    bool installer(List<String> a, String package) =>
        a.length == 7 &&
        sameJson(a.take(4).toList(), [
          'sudo',
          '-n',
          '/usr/sbin/installer',
          '-pkg',
        ]) &&
        path(a[4], package) &&
        sameJson(a.sublist(5), ['-target', '/']);
    final installed = find((a) => installer(a, oldArtifact), built);
    final upgraded = find((a) => installer(a, artifact), installed);
    continuous(
      installed,
      upgraded,
      (a) =>
          a.length >= 4 &&
          sameJson(a.take(3).toList(), ['sudo', '-n', '/bin/sh']) &&
          paths.basename(a[3]) == 'uninstall.sh',
    );
    final removed = find(
      (a) => sameJson(a, [
        'sudo',
        '-n',
        '/bin/sh',
        '/usr/local/lib/archway/uninstall.sh',
      ]),
      upgraded,
    );
    const absence = ['/usr/sbin/pkgutil', '--pkg-info', 'org.archway.cli'];
    if (old <= 1 || records.length <= removed + 1) {
      throw const FormatException('macOS receipt absence checks are missing');
    }
    for (var index = 0; index < records.length; index++) {
      final expectedAbsence = index == 0 || index == removed + 1;
      if (expectedAbsence
          ? records[index]['exit'] != 1 || !sameJson(args(index), absence)
          : records[index]['exit'] != 0 || sameJson(args(index), absence)) {
        throw const FormatException(
          'macOS receipt absence command failed, is duplicated, or reordered',
        );
      }
    }
  } else if (target == 'windows-x64') {
    bool prepared(List<String> a, bool finalBuild) =>
        builder(a, 'windows/prepare.dart', 4) &&
        path(a[2], bundle) == finalBuild;
    final old = find((a) => prepared(a, false));
    bool inno(List<String> a, String version, String inputs) =>
        a.length == 4 &&
        path(a[0], receipt['compiler']['path'] as String) &&
        a[1] == '/DAppVersion=$version' &&
        a[2].startsWith('/DOutputDir=') &&
        path(a[3], paths.join(inputs, 'archway.iss'));
    final oldBuilt = find((a) => inno(a, '0.0.0', args(old)[3]), old);
    final preparedFinal = find((a) => prepared(a, true), oldBuilt);
    final built = find(
      (a) => inno(a, version, args(preparedFinal)[3]),
      preparedFinal,
    );
    if (!path(args(built)[2].substring(12), paths.dirname(artifact))) {
      throw const FormatException(
        'Inno final compiler output differs from tested installer',
      );
    }
    final oldArtifact = paths.join(
      args(oldBuilt)[2].substring(12),
      'archway-0.0.0-windows-x64-unsigned.exe',
    );
    const switches = ['/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-'];
    bool invoke(List<String> a, String exe) =>
        a.length == 5 && path(a[0], exe) && sameJson(a.sublist(1), switches);
    final installed = find((a) => invoke(a, oldArtifact), built);
    final upgraded = find((a) => invoke(a, artifact), installed);
    final root = receipt['installed']['installation_root'] as String;
    bool uninstaller(List<String> a) =>
        path(paths.dirname(a[0]), root) &&
        paths.basename(a[0]).toLowerCase().startsWith('unins') &&
        paths.extension(a[0]).toLowerCase() == '.exe';
    continuous(installed, upgraded, uninstaller);
    find(
      (a) =>
          a.length == 5 && uninstaller(a) && sameJson(a.sublist(1), switches),
      upgraded,
    );
  } else {
    throw const FormatException('Unsupported native installer target');
  }
}
