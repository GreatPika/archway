// Workflow wiring guards; actual native installation remains a hosted CI gate.
import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

Map<dynamic, dynamic> workflow(String host) => loadYaml(
  File('.github/workflows/$host-native-probe.yml').readAsStringSync(),
) as Map;

List<dynamic> steps(Map<dynamic, dynamic> value) =>
    ((value['jobs'] as Map).values.single as Map)['steps'] as List;

void main() {
  for (final (host, target) in [
    ('macos', 'macos-arm64'),
    ('windows', 'windows-x64'),
  ]) {
    test('$host native export is opt-in and success-only', () {
      final value = workflow(host);
      expect((value['on'] as Map).keys.toSet(), {
        'workflow_call',
        'workflow_dispatch',
      });
      for (final event in ['workflow_call', 'workflow_dispatch']) {
        final option = value['on'][event]['inputs']['export-installation'];
        expect(option['type'], 'boolean');
        expect(option['default'], false);
        expect(option['required'], false);
      }
      expect(
        value['concurrency']['group'],
        contains("inputs.export-installation && 'export' || 'probe'"),
      );
      final all = steps(value);
      final uploads = all
          .where(
            (s) => (s['uses'] as String? ?? '').contains('upload-artifact@'),
          )
          .toList();
      expect(uploads, hasLength(2));
      final artifact = uploads.first;
      expect(
        artifact['uses'],
        'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02',
      );
      expect(artifact['if'], r'${{ success() && inputs.export-installation }}');
      final settings = artifact['with'] as Map;
      final destination = r'${{ runner.temp }}/archway-native-export-' + target;
      expect((settings['path'] as String).trim().split('\n'), [
        '$destination/installation.tar',
        '$destination/provenance.json',
      ]);
      expect(settings['retention-days'], 1);
      expect(settings['compression-level'], 0);
      expect(settings['if-no-files-found'], 'error');
      expect(settings.containsKey('overwrite'), isFalse);
      expect(
        settings['name'],
        contains(
          '$target-'
          r'${{ github.run_id }}-${{ github.run_attempt }}',
        ),
      );
      expect(uploads.last['if'], 'always()');
      expect(
        uploads.last['with']['path'],
        isNot(contains('archway-native-export')),
      );
      final checkout = all.indexWhere(
        (s) => (s['uses'] as String? ?? '').contains('checkout@'),
      );
      expect(checkout, greaterThanOrEqualTo(0));
      final preparation = all
          .take(checkout)
          .singleWhere(
            (s) => (s['run'] as String? ?? '').contains('core.autocrlf false'),
          );
      expect(preparation['if'], r'${{ inputs.export-installation }}');
      expect(
        preparation['run'],
        contains('git config --global core.autocrlf false'),
      );
      final setup = all.singleWhere((s) {
        final run = s['run'] as String? ?? '';
        return run.contains('pub get --enforce-lockfile') ||
            run.contains('-Phase setup');
      });
      expect(all.indexOf(setup), greaterThan(checkout));
      expect(
        setup['env']['EXPORT_INSTALLATION'],
        r'${{ inputs.export-installation }}',
      );
      final command = host == 'macos'
          ? setup['run'] as String
          : File('tool/ci/windows-native-probe.ps1').readAsStringSync();
      final verification = command.indexOf('verify_export_sources.dart');
      expect(verification, greaterThanOrEqualTo(0));
      expect(
        command.indexOf(host == 'macos' ? 'unzip' : 'Expand-Archive'),
        allOf(greaterThanOrEqualTo(0), lessThan(verification)),
      );
      expect(
        command.indexOf('pub get --enforce-lockfile'),
        greaterThan(verification),
      );
      expect(command, contains('GITHUB_SHA'));
      final assembly = all[all.indexOf(artifact) - 1] as Map;
      expect(assembly.containsKey('if'), isFalse);
      expect(assembly.containsKey('continue-on-error'), isFalse);
      expect(assembly['run'], contains('archway-native-export-$target'));
      final runs = all.map((s) => s['run'] ?? '').join('\n');
      expect(runs, isNot(contains('macos_aot_init_probe.py')));
      expect(runs, isNot(contains('-Phase aot-init')));
      expect(value.toString(), isNot(contains('continue-on-error')));
      if (host == 'macos') {
        expect(
          'native_assembly_init_probe.dart'.allMatches(runs),
          hasLength(1),
        );
      } else {
        expect(
          assembly['run'],
          contains(r"$arguments = @{ Phase = 'assembly-init' }"),
        );
      }
    });
  }

  test(
    'macOS assembly command forwards optional export and preserves failure',
    () async {
      final command =
          steps(workflow('macos')).singleWhere(
                (s) => (s['run'] as String? ?? '').contains(
                  'native_assembly_init_probe.dart',
                ),
              )['run']
              as String;
      final directory = Directory.systemTemp.createTempSync('export path ');
      addTearDown(() => directory.deleteSync(recursive: true));
      Directory('${directory.path}/build/macos-probe')
          .createSync(recursive: true);
      for (final (enabled, code) in [
        ('', 0),
        ('false', 0),
        ('true', 0),
        ('true', 7),
      ]) {
        final result = await Process.run(
          '/bin/bash',
          [
            '-eo',
            'pipefail',
            '-c',
            'dart() { printf "%s\\n" "\$@"; return "\$PROBE_EXIT"; };\n$command',
          ],
          workingDirectory: directory.path,
          environment: {
            'EXPORT_INSTALLATION': enabled,
            'RUNNER_TEMP': directory.path,
            'PROBE_EXIT': '$code',
          },
        );
        expect(result.exitCode, code, reason: '${result.stderr}');
        final args = (result.stdout as String).trim().split('\n');
        expect(args.contains('--artifact-directory'), enabled == 'true');
        if (enabled == 'true') {
          expect(
            args[args.indexOf('--artifact-directory') + 1],
            '${directory.path}/archway-native-export-macos-arm64',
          );
        }
      }
    },
    skip: Platform.isWindows
        ? 'POSIX shell dispatch; native macOS workflow remains required'
        : false,
  );

  test('Windows wrapper restricts export to final assembly', () {
    final wrapper = File('tool/ci/windows-native-probe.ps1').readAsStringSync();
    for (final fragment in [
      r"if ($ArtifactDirectory -and $Phase -ne 'assembly-init')",
      r"$arguments += @('--artifact-directory', $ArtifactDirectory)",
      r'& $dart @arguments',
      r'if (!(Test-Path "$evidence/aot-assets-passed.txt"))',
      r"$arguments = @('--suppress-analytics', 'run', 'tool/ci/native_assembly_init_probe.dart', '--init-only', '--dart', $dart)",
      r"if ($LASTEXITCODE -ne 0) { throw 'Maintainer assembly/init assertion failed;",
    ]) {
      expect(wrapper, contains(fragment));
    }
    expect(wrapper, isNot(contains("'aot-init'")));
    expect(wrapper, isNot(contains('aot-init-passed.txt')));
    expect(
      wrapper.indexOf("throw 'ArtifactDirectory"),
      allOf(
        greaterThanOrEqualTo(0),
        lessThan(wrapper.indexOf('Start-Transcript')),
      ),
    );
  });
}
