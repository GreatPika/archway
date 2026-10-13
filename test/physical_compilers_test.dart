import 'dart:io';
import 'dart:async';

import 'package:test/test.dart';
import 'package:path/path.dart' as p;

import 'dart_inspection_test.dart' show dartFixture;
import 'typescript_fixture.dart' as ts;
import 'physical_paths_test.dart' show checkPhysical;

void main() {
  test(
    'non-policy physical inputs retain repository locations and changes',
    () async {
      final root = await dartFixture(main: "import '../ignored/[bad].dart';");
      final policy = File('${root.path}/architecture.yaml');
      await policy.writeAsString(
        (await policy.readAsString()).replaceFirst(
          'exclude: []',
          'exclude: [lib/ignored/]',
        ),
      );
      final source = File('${root.path}/lib/ignored/[bad].dart');
      await source.parent.create();
      await source.writeAsString('class Odd {}');
      final report = await runZoned(
        () => checkPhysical(root, 2),
        zoneValues: {
          #archwayBeforeInputRecheck: () =>
              source.writeAsStringSync('class Changed {}'),
        },
      );
      final payload = report['payload'];
      expect(payload['facts']['edges'].single['resolution'], {
        'kind': 'unresolved',
      });
      final identity = payload['input_identity'];
      final location = {'kind': 'repository', 'path': 'lib/ignored/[bad].dart'};
      expect(identity['inputs'], contains(containsPair('location', location)));
      expect(identity['changed_inputs'], contains(equals(location)));
      expect(identity['rechecked'], true);
    },
  );

  test('one unreadable alias cannot prevent other recorded mappings from being rechecked', () async {
    final root = await dartFixture();
    await File('${root.path}/options.actual.yaml').writeAsString('{}');
    await File('${root.path}/options.other.yaml').writeAsString('{}');
    await Link('${root.path}/options.hop.yaml').create('options.actual.yaml');
    await Link('${root.path}/analysis_options.yaml').create('options.hop.yaml');
    final report = await runZoned(
      () => checkPhysical(root, 2),
      zoneValues: {
        #archwayBeforeInputRecheck: () {
          Link('${root.path}/analysis_options.yaml')
              .updateSync('analysis_options.yaml');
          Link('${root.path}/options.hop.yaml')
              .updateSync('options.other.yaml');
        },
      },
    );
    expect(report['payload']['analysis_complete'], false);
    expect(report['payload']['input_identity']['rechecked'], false);
    expect(
      report['payload']['input_identity']['changed_inputs'],
      contains(equals({'kind': 'repository', 'path': 'options.hop.yaml'})),
    );
    expect(
      (report['payload']['tool_errors'] as List).map((d) => d['code']),
      contains('INPUT_RECHECK_FAILED'),
    );
    expect(
      (report['payload']['violations'] as List).single['code'],
      'DEPENDENCY_NOT_ALLOWED',
    );
  });

  test('TypeScript config aliases retain intermediate link mappings', () async {
    final root = await ts.fixture(
      config: '{"extends":"./config.alias.json","include":["src/**/*.ts"]}',
    );
    await File('${root.path}/config.actual.json').writeAsString(
      '{"compilerOptions":{"target":"ES2022","module":"CommonJS"}}',
    );
    final outside = await Directory.systemTemp.createTemp(
      'archway-alias-hops-',
    );
    addTearDown(() => outside.delete(recursive: true));
    await Link('${outside.path}/config.hop.json')
        .create('${root.path}/config.actual.json');
    await Link('${root.path}/config.alias.json')
        .create('${outside.path}/config.hop.json');
    final report = await checkPhysical(root, 1);
    final aliases = report['payload']['input_identity']['aliases'] as List;
    expect(
      aliases,
      contains(
        equals({
          'observed_file_uri': File('${outside.path}/config.hop.json').uri
              .toString(),
          'canonical_file_uri': File('${root.path}/config.actual.json').uri
              .toString(),
        }),
      ),
    );
  });

  test('Dart config aliases retain every intermediate mapping for independent revalidation', () async {
    final root = await dartFixture();
    await File('${root.path}/options.actual.yaml')
        .writeAsString('analyzer:\n  language:\n    strict-casts: true\n');
    await Link('${root.path}/options.hop.yaml').create('options.actual.yaml');
    await Link('${root.path}/analysis_options.yaml').create('options.hop.yaml');
    final report = await checkPhysical(root, 1);
    final aliases = report['payload']['input_identity']['aliases'] as List;
    for (final name in ['analysis_options.yaml', 'options.hop.yaml']) {
      expect(
        aliases,
        contains(
          equals({
            'observed_file_uri': File('${root.path}/$name').uri.toString(),
            'canonical_file_uri': File('${root.path}/options.actual.yaml').uri
                .toString(),
          }),
        ),
      );
    }
  });

  for (final language in ['typescript', 'dart']) {
    test(
      '$language checks native alias semantics with a missing component before dot-dot',
      () async {
        final dart = language == 'dart';
        final root = dart
            ? await dartFixture()
            : await ts.fixture(
                config: '{"extends":"./config.alias.json","include":["src/**/*.ts"]}',
              );
        final target = 'actual.${dart ? 'yaml' : 'json'}';
        await File('${root.path}/$target').writeAsString('{}');
        final alias = Link(
          '${root.path}/${dart ? 'analysis_options.yaml' : 'config.alias.json'}',
        );
        final rawTarget = [
          'missing',
          '..',
          target,
        ].join(Platform.pathSeparator);
        await alias.create(rawTarget);
        expect(await alias.target(), rawTarget);
        final selected = File(alias.path);
        if (Platform.isWindows) {
          // Establish native readability independently of Archway's tracer.
          expect(await selected.readAsString(), '{}');
          expect(
            await selected.resolveSymbolicLinks(),
            await File('${root.path}/$target').resolveSymbolicLinks(),
          );
        } else {
          await expectLater(
            selected.readAsString(),
            throwsA(isA<FileSystemException>()),
          );
        }
        final report = await checkPhysical(root, Platform.isWindows ? 1 : 2);
        if (Platform.isWindows) {
          final payload = report['payload'];
          expect(report['status'], 'negative');
          expect(payload['analysis_complete'], true);
          expect(payload['tool_errors'], isEmpty);
          expect(payload['input_identity']['rechecked'], true);
          expect(payload['input_identity']['changed_inputs'], isEmpty);
          expect(
            payload['input_identity']['inputs'],
            contains(
              allOf(
                containsPair('location', {
                  'kind': 'repository',
                  'path': target,
                }),
                containsPair('presence', 'present'),
                containsPair(
                  'hash',
                  'sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a',
                ),
              ),
            ),
          );
          expect(
            payload['input_identity']['aliases'],
            contains(
              equals({
                'observed_file_uri': selected.uri.toString(),
                'canonical_file_uri': File('${root.path}/$target').uri
                    .toString(),
              }),
            ),
          );
          expect(payload['violations'], isNotEmpty);
        } else {
          expect(report['status'], 'incomplete');
          expect(report['payload']['tool_errors'], isNotEmpty);
        }
      },
    );

    test(
      '$language preserves a leading BOM as literal alias-target and filename text',
      () async {
        final dart = language == 'dart';
        final root = dart
            ? await dartFixture()
            : await ts.fixture(
                config: '{"extends":"./config.alias.json","include":["src/**/*.ts"]}',
              );
        final target = '\uFEFFconfig.${dart ? 'yaml' : 'json'}';
        await File('${root.path}/$target').writeAsString(
          dart
              ? '{}'
              : '{"compilerOptions":{"target":"ES2022","module":"CommonJS"}}',
        );
        await Link(
          '${root.path}/${dart ? 'analysis_options.yaml' : 'config.alias.json'}',
        ).create(target);
        final report = await checkPhysical(root, 1);
        expect(report['payload']['analysis_complete'], true);
        expect(
          (report['payload']['violations'] as List).single['code'],
          'DEPENDENCY_NOT_ALLOWED',
        );
      },
    );

    test(
      '$language absent probes retain and revalidate directory alias routes',
      () async {
        final dart = language == 'dart';
        final root = dart ? await dartFixture() : await ts.fixture();
        final directory = dart ? 'lib' : 'src';
        final extension = dart ? 'dart' : 'ts';
        await Directory('${root.path}/probeA').create();
        await Directory('${root.path}/probeB').create();
        final link = Link('${root.path}/$directory/app/probes');
        final firstTarget = p.join('..', '..', 'probeA');
        final secondTarget = p.join('..', '..', 'probeB');
        await link.create(firstTarget);
        // Raw Windows link targets use native separators. Establish a usable
        // directory route independently before testing absent compiler probes.
        expect(await link.target(), firstTarget);
        expect(
          await Directory(link.path).resolveSymbolicLinks(),
          await Directory('${root.path}/probeA').resolveSymbolicLinks(),
        );
        final policy = File('${root.path}/architecture.yaml');
        await policy.writeAsString(
          (await policy.readAsString()).replaceFirst(
            'exclude: []',
            'exclude: [$directory/app/probes/]',
          ),
        );
        final source = File('${root.path}/$directory/app/main.$extension');
        await source.writeAsString(
          "import './probes/missing.$extension';\n",
          mode: FileMode.append,
        );
        final report = await runZoned(
          () => checkPhysical(root, 2),
          zoneValues: {
            #archwayBeforeInputRecheck: () {
              link.updateSync(secondTarget);
              expect(link.targetSync(), secondTarget);
              expect(
                Directory(link.path).resolveSymbolicLinksSync(),
                Directory('${root.path}/probeB').resolveSymbolicLinksSync(),
              );
            },
          },
        );
        expect(report['payload']['input_identity']['rechecked'], true);
        final changed =
            report['payload']['input_identity']['changed_inputs'] as List;
        expect(
          changed.any(
            (value) =>
                (value['path'] as String? ?? '').contains('/probes/missing'),
          ),
          true,
        );
        expect(
          (report['payload']['violations'] as List).single['code'],
          'DEPENDENCY_NOT_ALLOWED',
        );
      },
    );

    test(
      '$language segment containment keeps a root-prefix sibling outside scope',
      () async {
        final dart = language == 'dart';
        final root = dart ? await dartFixture() : await ts.fixture();
        final outside = await Directory('${root.path}2').create();
        addTearDown(() => outside.delete(recursive: true));
        final extension = dart ? 'dart' : 'ts';
        final target = File('${outside.path}/private.$extension');
        await target.writeAsString(
          dart ? 'class Thing {}' : 'export const value=1;',
        );
        final source = File(
          '${root.path}/${dart ? 'lib' : 'src'}/app/main.$extension',
        );
        final relative = p
            .relative(target.path, from: source.parent.path)
            .split(p.separator)
            .join('/');
        await source.writeAsString(
          "import '${dart ? target.uri : relative}';\n",
        );
        final report = await checkPhysical(root, 1);
        expect(report['status'], 'negative');
        final resolution =
            (report['payload']['facts']['edges'] as List).single['resolution'];
        expect(resolution, {
          'kind': 'local',
          'path': null,
          'canonical_file_uri': target.uri.toString(),
          'via_path': null,
        });
        expect(
          (report['payload']['violations'] as List).single['code'],
          'LOCAL_TARGET_OUTSIDE_SCOPE',
        );
      },
    );

    test('$language detects stable same-target alias route changes', () async {
      final dart = language == 'dart';
      final root = dart
          ? await dartFixture()
          : await ts.fixture(
              config:
                  '{"extends":"./config.alias.json","include":["src/**/*.ts"]}',
            );
      final alias = dart ? 'analysis_options.yaml' : 'config.alias.json';
      final extension = dart ? 'yaml' : 'json';
      final content = dart
          ? '{}'
          : '{"compilerOptions":{"target":"ES2022","module":"CommonJS"}}';
      await File('${root.path}/actual.$extension').writeAsString(content);
      await Link('${root.path}/first.$extension').create('actual.$extension');
      await Link('${root.path}/second.$extension').create('actual.$extension');
      await Link('${root.path}/$alias').create('first.$extension');
      final report = await runZoned(
        () => checkPhysical(root, 2),
        zoneValues: {
          #archwayBeforeInputRecheck: () =>
              Link('${root.path}/$alias').updateSync('second.$extension'),
        },
      );
      expect(report['status'], 'incomplete');
      expect(report['payload']['input_identity']['rechecked'], true);
      expect(
        report['payload']['input_identity']['changed_inputs'],
        contains(equals({'kind': 'repository', 'path': alias})),
      );
      expect(
        (report['payload']['unknowns'] as List).map((d) => d['code']),
        contains('INPUT_CHANGED'),
      );
      expect(
        (report['payload']['violations'] as List).single['code'],
        'DEPENDENCY_NOT_ALLOWED',
      );
    });

    test(
      '$language hardlinks retain pathname owners and exact boundary decisions',
      () async {
        final dart = language == 'dart';
        final root = dart
            ? await dartFixture(
                main:
                    "import './shared.dart';\nimport '../core/private.dart';\n",
              )
            : await ts.fixture(
                main: "import './shared';\nimport '../core/private';\n",
              );
        final directory = dart ? 'lib' : 'src';
        final extension = dart ? 'dart' : 'ts';
        final linked = await Process.run('/bin/ln', [
          '${root.path}/$directory/core/private.$extension',
          '${root.path}/$directory/app/shared.$extension',
        ]);
        expect(linked.exitCode, 0);
        final report = await checkPhysical(root, 1);
        expect(report['status'], 'negative');
        expect(report['payload']['analysis_complete'], true);
        final edges = report['payload']['facts']['edges'] as List;
        expect(edges.map((e) => e['resolution']['path']), [
          '$directory/app/shared.$extension',
          '$directory/core/private.$extension',
        ]);
        expect(
          (report['payload']['violations'] as List).single['code'],
          'DEPENDENCY_NOT_ALLOWED',
        );
        expect(report['payload']['input_identity']['aliases'], isEmpty);
      },
      skip: !Platform.isLinux,
    );
  }
}
