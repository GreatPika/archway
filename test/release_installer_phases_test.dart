import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../tool/ci/release_installer_phases.dart';
import 'native_installer_receipt_fixtures.dart';

void main() {
  test('macOS builder digest binds exact UTF-8 path bytes', () {
    final e = InstallerEvidence('macos-arm64');
    addTearDown(() => e.root.deleteSync(recursive: true));
    final argv = List<String>.from(e.commands[3]['arguments'] as List);
    argv[5] += '/replacement-�';
    final line =
        '${e.receipt['artifact']['sha256']}  ${e.paths.join(argv[5], 'archway-0.1.0-macos-arm64-unsigned.pkg')}\n';
    final record = e.record(argv, 'byte-digest', stdout: line);
    e.commands[3] = record;
    validateInstallerPhases(e.proof, e.directory, e.paths);
    final bytes = utf8.encode(line).toList();
    final index = bytes.indexOf(0xef);
    bytes.replaceRange(index, index + 3, [0xff]);
    File(p.join(e.directory.path, record['stdout'] as String))
        .writeAsBytesSync(bytes);
    record['stdout_sha256'] = InstallerEvidence.hash(bytes);
    expect(
      () => validateInstallerPhases(e.proof, e.directory, e.paths),
      throwsFormatException,
    );
  });
  for (final target in ['linux-x64', 'macos-arm64', 'windows-x64']) {
    for (final change in [
      'drop-build',
      'swap-build',
      'drop-upgrade',
      'wrong-remove',
      'wrong-artifact',
      'insert-reset',
      'python-builder',
    ]) {
      test('$target rejects $change', () {
        final e = InstallerEvidence(target);
        addTearDown(() => e.root.deleteSync(recursive: true));
        final indices = {
          'linux-x64': [1, 2, 3, 4, 5],
          'macos-arm64': [2, 3, 4, 5, 6],
          'windows-x64': [1, 3, 5, 6, 7],
        }[target]!;
        final records = e.commands;
        switch (change) {
          case 'drop-build':
            records.removeAt(indices[0]);
          case 'swap-build':
            final old = records[indices[0]];
            records[indices[0]] = records[indices[1]];
            records[indices[1]] = old;
          case 'drop-upgrade':
            records.removeAt(indices[3]);
          case 'wrong-remove':
            records[indices[4]]['arguments'][0] = 'different-tool';
          case 'wrong-artifact':
            records[indices[3]]['arguments'] =
                (records[indices[3]]['arguments'] as List<String>)
                    .map((s) => s.replaceAll('0.1.0', '0.9.9'))
                    .toList();
          case 'insert-reset':
            final reset = e.record(
              List<String>.from(records[indices[4]]['arguments'] as List),
              'reset',
            );
            records.insert(indices[3], reset);
          case 'python-builder':
            e.proof['acceptance']['python'] = e.at('python');
            records[indices[0]]['arguments'][0] = e.at('python');
        }
        expect(
          () => validateInstallerPhases(e.proof, e.directory, e.paths),
          throwsFormatException,
        );
      });
    }
    test('$target binds every builder operand', () {
      final e = InstallerEvidence(target);
      addTearDown(() => e.root.deleteSync(recursive: true));
      final indices = {
        'linux-x64': [1, 2],
        'macos-arm64': [2, 3],
        'windows-x64': [1, 3],
      }[target]!;
      for (final index in indices) {
        final argv = e.commands[index]['arguments'] as List<String>;
        for (var operand = 0; operand < argv.length; operand++) {
          // Old source payloads must differ, but have no fixed absolute path.
          if (index == indices.first &&
              operand == (target == 'windows-x64' ? 2 : 3))
            continue;
          final original = argv[operand];
          argv[operand] = '$original-changed';
          expect(
            () => validateInstallerPhases(e.proof, e.directory, e.paths),
            throwsFormatException,
            reason: '$target phase $index operand $operand',
          );
          argv[operand] = original;
        }
      }
    });
  }
  test('same dpkg root reset is rejected despite changed log destination', () {
    final e = InstallerEvidence('linux-x64');
    addTearDown(() => e.root.deleteSync(recursive: true));
    final argv = List<String>.from(e.commands.last['arguments'] as List)
      ..[4] = '--log=/elsewhere.log';
    e.commands.insert(4, e.record(argv, 'reset'));
    expect(
      () => validateInstallerPhases(e.proof, e.directory, e.paths),
      throwsFormatException,
    );
    argv[3] = '--root=/fixture/other-system';
    validateInstallerPhases(e.proof, e.directory, e.paths);
  });
  for (final change in [
    'missing-initial',
    'missing-final',
    'late-initial',
    'early-final',
    'duplicate',
    'wrong-command',
    'other-failure',
    'wrong-exit',
  ]) {
    test('macOS rejects $change absence record', () {
      final e = InstallerEvidence('macos-arm64');
      addTearDown(() => e.root.deleteSync(recursive: true));
      switch (change) {
        case 'missing-initial':
          e.commands.removeAt(0);
        case 'missing-final':
          e.commands.removeLast();
        case 'late-initial':
          e.commands.insert(2, e.commands.removeAt(0));
        case 'early-final':
          e.commands.insert(6, e.commands.removeLast());
        case 'duplicate':
          e.commands.add(
            e.record(
              List<String>.from(e.commands.first['arguments'] as List),
              'duplicate',
              exit: 1,
            ),
          );
        case 'wrong-command':
          e.commands.first['arguments'][2] = 'org.someone.else';
        case 'other-failure':
          e.commands[1]['exit'] = 1;
        case 'wrong-exit':
          e.commands.last['exit'] = 2;
      }
      expect(
        () => validateInstallerPhases(e.proof, e.directory, e.paths),
        throwsFormatException,
      );
    });
  }

  test('Windows binds Dart preparation to ordered compiler and lifecycle', () {
    final e = InstallerEvidence('windows-x64');
    addTearDown(() => e.root.deleteSync(recursive: true));
    validateInstallerPhases(e.proof, e.directory, e.paths);
    e.commands[4]['arguments'][2] = '/DOutputDir=C:\\different';
    expect(
      () => validateInstallerPhases(e.proof, e.directory, e.paths),
      throwsFormatException,
    );
  });
  test('macOS binds two truthful absence checks around its lifecycle', () {
    final e = InstallerEvidence('macos-arm64');
    addTearDown(() => e.root.deleteSync(recursive: true));
    validateInstallerPhases(e.proof, e.directory, e.paths);
    e.commands.first['exit'] = 0;
    expect(
      () => validateInstallerPhases(e.proof, e.directory, e.paths),
      throwsFormatException,
    );
  });
  test('binds Debian Dart builds and ordered install upgrade remove', () {
    final e = InstallerEvidence('linux-x64');
    addTearDown(() => e.root.deleteSync(recursive: true));
    validateInstallerPhases(e.proof, e.directory, e.paths);
    e.commands[1]['arguments'][0] = '/unproven/dart';
    expect(
      () => validateInstallerPhases(e.proof, e.directory, e.paths),
      throwsFormatException,
    );
  });
}
