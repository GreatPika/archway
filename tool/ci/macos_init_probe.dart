// Source-seam feasibility only, not installation/platform certification.
// Expected result: contracts/json/decision.md, success and Safe init sections.
import 'dart:convert';
import 'dart:io';

import 'package:archway/src/cli/cli.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> args) async {
  require(
    args.length == 1 && {'policy', 'init'}.contains(args.single),
    'Select policy or init.',
  );
  final mode = args.single;
  final temporary = await Directory.systemTemp.createTemp('archway-$mode-');
  // macOS /var and /tmp can be aliases. Test native init, not incidental aliases.
  final root = Directory(await temporary.resolveSymbolicLinks());
  try {
    require(await root.list().isEmpty, 'The root must start empty.');
    if (mode == 'policy') {
      await File('${root.path}/architecture.yaml').writeAsString(
        'version: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
      );
    }
    final out = StringBuffer();
    final err = StringBuffer();
    final command = mode == 'policy' ? 'validate' : 'init';
    final invocation = [
      command,
      '--root',
      root.path,
      if (mode == 'init') ...['--template', 'mixed'],
    ];
    print('CLI.run ${jsonEncode(invocation)}');
    final code = await CLI().run(invocation, CliStreams(out, err));
    print('Returned exit code: $code');
    print('CLI stdout: ${out.toString()}');
    print('CLI stderr: ${err.toString()}');
    // Do not catch/accept unsupported-host errors or assert that failure is OK.
    require(code == 0, '$command contract requires exit 0; actual exit $code.');
    require(err.isEmpty, '$command must not emit stderr on this fixture.');
    require(
      out.toString().endsWith('\n') &&
          '\n'.allMatches(out.toString()).length == 1,
      'Expected one JSON object followed by LF.',
    );
    final result = jsonDecode(out.toString()) as Map<String, dynamic>;
    require(
      result['status'] == 'ok' && result['exit_code'] == 0,
      'Expected successful envelope.',
    );
    if (mode == 'init') {
      final payload = result['payload'] as Map<String, dynamic>;
      require(
        payload['outcome'] == 'created',
        'Expected created init outcome.',
      );
      final names = await root
          .list()
          .map((e) => e.uri.pathSegments.last)
          .toList();
      names.sort();
      require(
        jsonEncode(names) ==
            jsonEncode(['ARCHITECTURE.md', 'architecture.yaml']),
        'Expected exactly the two contractual init files.',
      );
      require(
        await File('${root.path}/architecture.yaml').readAsString() == '# Archway: mixed template\nversion: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
        'Unexpected policy bytes.',
      );
    } else {
      require(
        result['payload']['policy_valid'] == true,
        'Expected a valid empty policy.',
      );
    }
    print('$mode source-seam assertion passed.');
  } finally {
    await root.delete(recursive: true);
  }
}
