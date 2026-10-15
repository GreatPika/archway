// Release wiring guards and actual shell dispatch; never hosted acceptance proof.
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

Map<String, dynamic> object(Object? value) =>
    Map<String, dynamic>.from(value as Map);
List<Map<String, dynamic>> steps(Map<String, dynamic> job) =>
    (job['steps'] as List).map(object).toList();
String runs(Map<String, dynamic> job) =>
    steps(job).map((s) => s['run'] ?? '').join('\n');
Map<String, dynamic> download(Map<String, dynamic> job, String prefix) =>
    steps(job).singleWhere(
      (s) =>
          '${s['uses']}'.startsWith('actions/download-artifact@') &&
          '${object(s['with'])['name']}'.startsWith(prefix),
    );
const attempt = r'${{ github.run_id }}-${{ github.run_attempt }}';
const hosts = {
  'ubuntu-24.04': 'linux-x64',
  'macos-15': 'macos-arm64',
  'windows-2025': 'windows-x64',
};

void main() {
  test(
    'retired Python discovery leaves every replacement in source inventory',
    () {
      // The production source gate copies exact tracked bytes without .git.
      // Inspect that runnable source tree; the outer gate binds it to Git and
      // rejects missing or additional observed Dart suites independently.
      final sources = <String>{
        for (final directory in ['contracts', 'test', 'tool', 'bin', '.github'])
          for (final file in Directory(
            directory,
          ).listSync(recursive: true, followLinks: false).whereType<File>())
            file.path.replaceAll('\\', '/'),
      };
      expect(sources.where((path) => path.endsWith('.py')), isEmpty);
      final discovered = sources
          .where(
            (path) => path.startsWith('test/') && path.endsWith('_test.dart'),
          )
          .toSet();
      expect(
        discovered,
        containsAll([
          'test/native_export_workflow_test.dart',
          'test/runtime_capture_test.dart',
          'test/windows_installer_path_evidence_test.dart',
          'test/native_source_report_test.dart',
          'test/npm_portable_bin_test.dart',
        ]),
      );
    },
  );
  final workflow = object(
    loadYaml(
      File('.github/workflows/package-delivery-probe.yml').readAsStringSync(),
    ),
  );
  final jobs = object(workflow['jobs']);
  Map<String, dynamic> job(String name) => object(jobs[name]);
  test('release producers are source-pinned, native-first and same-attempt', () {
    expect(workflow['permissions'], {'contents': 'read'});
    expect(
      object(object(workflow['on'])['push'])['branches'],
      unorderedEquals(['main', 'integration/archway-v1', 'release/**']),
    );
    final intent = object(
      object(object(workflow['on'])['workflow_dispatch'])['inputs'],
    );
    expect(object(intent['registry-ready'])['type'], 'boolean');
    expect(object(intent['registry-ready'])['default'], isFalse);
    expect(object(workflow['env'])['PUB_HOSTED_URL'], 'https://pub.dev');
    expect(
      object(workflow['env'])['ARCHWAY_REGISTRY_READY'],
      r"${{ github.event_name == 'workflow_dispatch' && toJSON(inputs.registry-ready) || 'false' }}",
    );
    expect(
      object(object(workflow['on'])['push'])['paths'],
      unorderedEquals([
        '.github/workflows/**',
        'tool/**',
        'test/**',
        'lib/**',
        'bin/**',
        'assets/**',
        'native/**',
        'contracts/**',
        'pubspec.yaml',
        'pubspec.lock',
        'analysis_options.yaml',
        'README.md',
        'LICENSE',
      ]),
    );
    for (final target in ['macos', 'windows']) {
      expect(job(target), {
        'uses': './.github/workflows/$target-native-probe.yml',
        'with': {'export-installation': true},
      });
    }

    const actions = {
      'actions/checkout': '11bd71901bbe5b1630ceea73d27597364c9af683',
      'actions/download-artifact': 'd3f86a106a0bac45b974a628896c90dbdf5c8093',
      'actions/upload-artifact': 'ea165f8d65b6e75b540449e92b4886f43607fa02',
      'actions/setup-node': '49933ea5288caeca8642d1e84afbd3f7d6820020',
    };
    for (final value in jobs.values) {
      final current = object(value);
      expect(current.containsKey('if'), isFalse);
      expect(current.containsKey('continue-on-error'), isFalse);
      expect(current.containsKey('secrets'), isFalse);
      for (final step in (current['steps'] as List? ?? []).map(object)) {
        expect(step.containsKey('continue-on-error'), isFalse);
        if (step['uses'] case final String action) {
          final parts = action.split('@');
          expect(parts.length, 2);
          expect(parts[1], actions[parts[0]]);
          if (parts[0] == 'actions/checkout')
            expect(step['with'], {
              'persist-credentials': false,
              'ref': r'${{ github.sha }}',
            });
          if (parts[0] == 'actions/setup-node')
            expect(step['with'], {'node-version': '24.21.0'});
        }
      }
    }
    expect(
      job('audit')['needs'],
      unorderedEquals(['linux', 'macos', 'windows']),
    );
    for (final target in hosts.values) {
      expect(download(job('audit'), 'native-installation-$target-')['with'], {
        'name': 'native-installation-$target-$attempt',
        'path': 'transports/$target',
      });
    }
    expect(
      steps(job('audit'))
          .where((s) => '${s['uses']}'.startsWith('actions/download-artifact@'))
          .length,
      3,
    );
    final audit = runs(job('audit'));
    expect(audit, contains(r'test "$(node --version)" = v24.21.0'));
    expect(audit, contains(r'test "$(npm --version)" = 11.19.0'));
    final producers = {
      for (final owner in [
        'audit_installation_transports.dart',
        'tool/prepare_typescript.sh',
        'build_native_archives.dart',
        'generate_descriptor.dart',
        'tool/npm/stage.dart',
        'tool/npm/pack.dart',
        'tool/pub/stage.dart',
        'tool/ci/pub_stage_transport.dart write',
      ])
        owner: audit.indexOf(owner),
    };
    for (final owner in producers.keys) {
      expect(audit.split(owner).length - 1, 1);
    }
    for (final chain in [
      [
        'audit_installation_transports.dart',
        'tool/prepare_typescript.sh',
        'build_native_archives.dart',
        'generate_descriptor.dart',
      ],
      ['generate_descriptor.dart', 'tool/npm/stage.dart', 'tool/npm/pack.dart'],
      [
        'generate_descriptor.dart',
        'tool/pub/stage.dart',
        'tool/ci/pub_stage_transport.dart write',
      ],
    ]) {
      for (var i = 1; i < chain.length; i++) {
        expect(
          producers[chain[i]],
          greaterThan(producers[chain[i - 1]]!),
          reason: '${chain[i]} requires ${chain[i - 1]}',
        );
      }
    }
    expect(audit, contains('--expected-commit "\$GITHUB_SHA"'));
    expect(
      audit,
      contains(
        '--run-id "\$GITHUB_RUN_ID" --run-attempt "\$GITHUB_RUN_ATTEMPT"',
      ),
    );
    expect(
      audit,
      contains(
        'npm ci --ignore-scripts --prefix tool/npm --no-audit --no-fund',
      ),
    );
    expect(audit, contains('if [[ "\$ARCHWAY_REGISTRY_READY" == true ]]'));
    expect(audit, contains('tool/pub/export.dart'));
    expect(audit, isNot(contains('npm publish')));
    expect(job('audit')['outputs'], {
      'pub-transport': r'${{ steps.pub-transport.outputs.identity }}',
    });
    for (final (prefix, paths) in [
      ('release-bundles-', [r'${{ runner.temp }}/archway-native-bundles/']),
      (
        'acquisition-descriptor-',
        [r'${{ runner.temp }}/archway-acquisition/acquisition.json'],
      ),
      ('private-npm-pack-', [r'${{ runner.temp }}/archway-npm-packed/']),
      (
        'private-pub-stage-',
        [
          r'${{ runner.temp }}/archway-pub-transport/installation.tar',
          r'${{ runner.temp }}/archway-pub-transport/transport.json',
        ],
      ),
    ]) {
      final upload = steps(job('audit')).singleWhere(
        (step) => '${object(step['with'] ?? {})['name']}'.startsWith(prefix),
      );
      final settings = object(upload['with']);
      expect(upload['if'], 'success()');
      expect(settings['name'], '$prefix$attempt');
      expect('${settings['path']}'.trim().split('\n'), unorderedEquals(paths));
      expect(settings['retention-days'], 1);
      expect(settings['if-no-files-found'], 'error');
      expect(settings.containsKey('overwrite'), isFalse);
      if (prefix != 'acquisition-descriptor-')
        expect(settings['compression-level'], 0);
    }
    final diagnostics = steps(job('audit')).singleWhere(
      (step) => '${object(step['with'] ?? {})['name']}'.startsWith(
        'pub-producer-evidence-',
      ),
    );
    expect(diagnostics['if'], 'always()');
    expect(object(diagnostics['with'])['retention-days'], 1);
    expect(
      object(diagnostics['with'])['name'],
      'pub-producer-evidence-$attempt',
    );
    expect(
      '${object(diagnostics['with'])['path']}'.trim().split('\n'),
      unorderedEquals([
        'build/pub-producer/',
        r'${{ runner.temp }}/archway-pub-export-execution/',
        r'${{ runner.temp }}/archway-pub-setup/report.json',
        r'${{ runner.temp }}/archway-pub-setup/execution/',
      ]),
    );
    for (final owner in [
      'tool/npm/stage.dart',
      'tool/pub/stage.dart',
      'tool/ci/pub_stage_transport.dart write',
      'tool/npm/installed_probe.dart',
      'tool/ci/pub_installed_route.dart',
      'tool/ci/finalize_native_first_release.dart',
    ]) {
      final caller = jobs.values
          .where((value) => object(value).containsKey('steps'))
          .expand((value) => steps(object(value)))
          .singleWhere((step) => '${step['run']}'.contains(owner));
      final script = caller['run'] as String;
      expect(
        script,
        contains('source tool/ci/registry_candidate_arguments.sh'),
      );
      final command = script
          .replaceAll('\\\n', ' ')
          .split('\n')
          .singleWhere((line) => line.contains(owner));
      expect(command, contains(r'${registry_args[@]+"${registry_args[@]}"}'));
    }
    final native = job('release-native');
    expect(native['needs'], ['audit']);
    expect(native['runs-on'], r'${{ matrix.os }}');
    expect(native['timeout-minutes'] as int, greaterThanOrEqualTo(45));
    final nativeStrategy = object(native['strategy']);
    expect(nativeStrategy['fail-fast'], isFalse);
    expect(
      object(nativeStrategy['matrix'])['include'],
      unorderedEquals([
        for (final host in hosts.entries)
          {'os': host.key, 'target': host.value},
      ]),
    );
    expect(download(native, 'release-bundles-')['with'], {
      'name': 'release-bundles-$attempt',
      'path': 'release-input',
    });
    final nativeSteps = steps(native);
    final nativeScript = runs(native);
    var previousPreparation = -1;
    for (final owner in [
      'tool/ci/bootstrap_pub_dart.sh',
      'tool/ci/prepare_locked_checkout.dart',
      'git diff --exit-code -- pubspec.lock',
      'tool/ci/verify_export_sources.dart',
      'tool/ci/prepare_native_acceptance.dart',
      'tool/ci/native_fixture_controls.dart fixtures',
      'tool/ci/release_native_smoke.dart',
    ]) {
      final offset = nativeScript.indexOf(owner);
      expect(offset, greaterThan(previousPreparation), reason: owner);
      previousPreparation = offset;
      final step = nativeSteps.singleWhere(
        (s) => '${s['run']}'.contains(owner),
      );
      expect(step.containsKey('if'), isFalse, reason: owner);
    }
    final npmPreparation = nativeSteps.singleWhere(
      (step) => '${step['run']}'.contains('npm ci'),
    );
    final nativeExecution = nativeSteps.singleWhere(
      (step) => '${step['run']}'.contains('tool/ci/release_native_smoke.dart'),
    );
    for (final flag in [
      r'"$NATIVE_DART" --suppress-analytics run tool/ci/release_native_smoke.dart',
      '--ci-host',
      '--installer-checks',
      r'--expected-commit "$GITHUB_SHA"',
      r'--acceptance-fixtures "$RUNNER_TEMP/archway-native-fixtures/acceptance-fixtures.json"',
    ]) {
      expect(nativeExecution['run'], contains(flag));
    }
    expect(
      nativeSteps.indexOf(npmPreparation),
      lessThan(nativeSteps.indexOf(nativeExecution)),
    );
    final linuxUpload = steps(job('linux')).singleWhere(
      (s) => '${object(s['with'] ?? {})['name']}'.startsWith(
        'native-installation-',
      ),
    );
    expect(linuxUpload['if'], 'success()');
    expect(
      '${object(linuxUpload['with'])['path']}'.trim().split('\n').toSet(),
      {
        r'${{ runner.temp }}/archway-native-export-linux-x64/installation.tar',
        r'${{ runner.temp }}/archway-native-export-linux-x64/provenance.json',
      },
    );
  });

  test('installed matrices consume immutable artifacts and retain bounded failed-cell evidence', () {
    for (final channel in ['npm', 'pub']) {
      final current = job('$channel-installed');
      expect(current['needs'], ['audit']);
      expect(current['runs-on'], r'${{ matrix.os }}');
      final strategy = object(current['strategy']),
          matrix = object(object(current['strategy'])['matrix']);
      expect(strategy['fail-fast'], isFalse);
      expect(matrix['include'] as List, hasLength(3));
      expect(
        (matrix['include'] as List)
            .map(object)
            .map((r) => '${r['os']}:${r['target']}')
            .toSet(),
        hosts.entries.map((e) => '${e.key}:${e.value}').toSet(),
      );
      if (channel == 'npm') {
        expect(matrix.keys, unorderedEquals(['os', 'route', 'include']));
        expect(matrix['os'], unorderedEquals(hosts.keys));
        expect(matrix['route'], unorderedEquals(['local', 'global', 'cache']));
        final capability = steps(current).singleWhere(
          (s) => '${s['run']}'.contains('test/windows_job_capability.dart'),
        );
        expect(capability['if'], "runner.os == 'Windows'");
        expect(
          capability['run'],
          contains('test/windows_job_readiness_test.dart'),
        );
        expect(capability['run'], contains('set -euo pipefail'));
        expect(
          steps(current).indexOf(capability),
          lessThan(
            steps(current).indexWhere(
              (s) => '${s['run']}'.contains('tool/npm/installed_probe.dart'),
            ),
          ),
        );
      } else {
        expect(matrix.keys, ['include']);
      }
      expect(download(current, 'release-bundles-')['with'], {
        'name': 'release-bundles-$attempt',
        'path': 'native-input',
      });
      expect(download(current, 'acquisition-descriptor-')['with'], {
        'name': 'acquisition-descriptor-$attempt',
        'path': 'acquisition-input',
      });
      expect(download(current, 'private-$channel-')['with'], {
        'name':
            'private-${channel == 'npm' ? 'npm-pack' : 'pub-stage'}-$attempt',
        'path': '$channel-input',
      });
      final script = runs(current);
      if (channel == 'pub') {
        final probe = steps(current).singleWhere(
          (step) =>
              '${step['run']}'.contains('tool/ci/pub_installed_route.dart'),
        );
        expect(probe['env'], {
          'EXPECTED_PUB_TRANSPORT': r'${{ needs.audit.outputs.pub-transport }}',
        });
      }
      expect(script, isNot(contains(r'${{ needs.')));

      expect(script, contains('bootstrap_pub_dart.sh'));
      expect(script, contains('pub get --enforce-lockfile'));
      expect(script, contains('setup_npm_wrong_node.dart'));
      expect(script, isNot(contains('tool/npm/pack.dart')));
      expect(script, isNot(contains('tool/pub/stage.dart')));
      final retained = steps(current).singleWhere(
        (s) => '${s['uses']}'.startsWith('actions/upload-artifact@'),
      );
      expect(retained['if'], 'always()');
      final prefix = channel == 'npm'
          ? 'npm-installed-${r'${{ matrix.route }}'}-'
          : 'pub-installed-';
      expect(retained['with'], {
        'name': '$prefix${r'${{ matrix.target }}'}-$attempt',
        'path': 'build/${channel == 'npm' ? 'npm-local' : 'pub-installed'}/',
        'retention-days': 1,
        'if-no-files-found': 'warn',
      });
      final projection = steps(
        current,
      ).singleWhere((s) => '${s['run']}'.contains('cp "\$probe/report.json"'));
      expect(projection['if'], 'always()');
      expect(projection['run'], isNot(contains('cp -R "\$probe"')));
      expect(projection['run'], contains('runtime.json'));
      if (channel == 'pub') {
        expect(projection['run'], contains('sdk-preparation-execution'));
        expect(projection['run'], contains('sdk-preparation.json'));
        expect(
          projection['run'],
          contains('activation execution private-export'),
        );
      } else {
        expect(projection['run'], contains('"\$probe/processes"'));
      }
    }
    final finalizer = job('release-finalize');
    expect(
      finalizer['needs'],
      unorderedEquals([
        'audit',
        'release-native',
        'npm-installed',
        'pub-installed',
      ]),
    );
    final script = runs(finalizer);
    expect(script, contains('tool/ci/finalize_native_first_release.dart'));
    for (final flag in [
      '--source',
      '--expected-commit',
      '--native-directory',
      '--descriptor',
      '--npm-packed',
      '--pub-transport',
      '--reports',
      '--installed-evidence',
      '--run-id',
      '--run-attempt',
      '--expected-pub-transport-json',
      '--output',
    ]) {
      expect(script, contains(flag));
    }
    for (final name in ['npm', 'pub']) {
      expect(
        steps(finalizer).singleWhere(
          (s) => '${object(s['with'] ?? {})['pattern']}'.startsWith(
            '$name-installed-',
          ),
        )['with'],
        {
          'pattern': '$name-installed-*-$attempt',
          'path': 'installed-routes/$name',
        },
      );
    }
  });

  test('existing Linux source and native export gates remain ordered', () {
    final linux = job('linux'), pipeline = steps(job('linux'));
    expect(linux['runs-on'], 'ubuntu-24.04');
    final script = runs(linux);
    final order = [
      'unzip',
      'verify_export_sources.dart',
      'pub get --enforce-lockfile',
      'bash tool/prepare_typescript.sh',
      'tool/ci/native_assembly_init_probe.dart',
    ];
    var previous = -1;
    for (final command in order) {
      final offset = script.indexOf(command);
      expect(offset, greaterThan(previous));
      previous = offset;
    }
    expect(script, isNot(contains('python')));
    expect(script, isNot(contains('jsonschema')));
    expect(script, isNot(contains('PyYAML')));
    // Full source discovery belongs to the prepared three-host native gate.
    final native = job('release-native');
    expect(native.containsKey('if'), isFalse);
    expect(native.containsKey('continue-on-error'), isFalse);
    final execution = steps(native).singleWhere(
      (step) => '${step['run']}'.contains('tool/ci/release_native_smoke.dart'),
    );
    expect(execution.containsKey('if'), isFalse);
    expect(execution.containsKey('continue-on-error'), isFalse);
    expect(execution['run'], contains('--ci-host'));
    expect(job('release-finalize')['needs'], contains('release-native'));
    for (final flag in [
      '--dart-sdk',
      '--node',
      '--artifact-directory',
      'sha256sum -c -',
    ]) {
      expect(script, contains(flag));
    }
    final retained = pipeline
        .where(
          (step) => '${step['uses']}'.startsWith('actions/upload-artifact@'),
        )
        .toList();
    expect(retained.length, 2);
    for (final step in retained) {
      final settings = object(step['with']);
      expect(settings['retention-days'], 1);
      expect(settings.containsKey('overwrite'), isFalse);
      if ('${settings['name']}'.startsWith('native-installation-')) {
        expect(settings['if-no-files-found'], 'error');
        expect(settings['compression-level'], 0);
      } else {
        expect(step['if'], 'always()');
      }
    }
  });

  if (!Platform.isWindows)
    test('native source preparation exports its locked npm cache only after success', () async {
      final preparation = steps(job('release-native'))
          .singleWhere((step) => '${step['run']}'.contains('npm ci'));
      for (final exit in [0, 37]) {
        final root = Directory.systemTemp.createTempSync(
          'npm preparation café-',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final temporary = Directory(p.join(root.path, 'temporary'))
          ..createSync();
        final capture = File(p.join(root.path, 'npm-arguments'));
        final exported = File(p.join(root.path, 'github-environment'));
        final result = await Process.run(
          'bash',
          [
            '-c',
            r'''
npm() {
  printenv npm_config_cache > "$CAPTURE"
  printf '%s\n' "$PWD" "$@" >> "$CAPTURE"
  printf 'original npm preparation output\n'
  return "$NPM_EXIT"
}
''' +
                (preparation['run'] as String),
          ],
          workingDirectory: root.path,
          environment: {
            ...Platform.environment,
            'RUNNER_TEMP': temporary.path,
            'GITHUB_ENV': exported.path,
            'CAPTURE': capture.path,
            'NPM_EXIT': '$exit',
          }..remove('npm_config_cache'),
          includeParentEnvironment: false,
        ).timeout(const Duration(seconds: 20));
        expect(result.exitCode, exit);
        final arguments = capture.readAsLinesSync();
        expect(arguments[1], root.resolveSymbolicLinksSync());
        final command = arguments.sublist(2);
        expect(command.first, 'ci');
        final prefix = command.indexOf('--prefix');
        expect(prefix, greaterThan(0));
        expect(command[prefix + 1], 'tool/npm');
        command.removeRange(prefix, prefix + 2);
        expect(
          command.skip(1),
          unorderedEquals(['--ignore-scripts', '--no-audit', '--no-fund']),
        );
        expect(p.isWithin(temporary.path, arguments[0]), isTrue);
        expect(
          File(p.join(root.path, 'build/release-native/npm-setup.log'))
              .readAsStringSync(),
          'original npm preparation output\n',
        );
        if (exit == 0) {
          expect(exported.readAsLinesSync(), [
            'npm_config_cache=${arguments[0]}',
          ]);
        } else {
          expect(exported.existsSync(), isFalse);
        }
      }
    });

  test(
    'malformed transport cannot publish a successful workflow output',
    () async {
      final producer = steps(job('audit'))
          .singleWhere((step) => step['id'] == 'pub-transport');
      final root = Directory.systemTemp.createTempSync(
        'transport output café-',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final identity = File(
        p.join(root.path, 'build/pub-producer/identity.json'),
      );
      identity.parent.createSync(recursive: true);
      identity.writeAsStringSync('{invalid JSON');
      final output = File(p.join(root.path, 'job-output'));
      final result = await Process.run(
        'bash',
        ['-c', producer['run'] as String],
        workingDirectory: root.path,
        environment: {...Platform.environment, 'GITHUB_OUTPUT': output.path},
      );
      expect(result.exitCode, isNot(0));
      expect(output.existsSync(), isFalse);
    },
    skip: Platform.isWindows
        ? 'POSIX shell output guard; native host workflow remains required'
        : false,
  );
}
