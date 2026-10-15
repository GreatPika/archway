// Controlled CLI responses test the probe itself, never compiler acceptance.
import 'dart:convert';
import 'dart:io';

import 'aot_init_oracle_child.dart' as init;

void main(List<String> args) {
  if (args.first == '--fixture-route') {
    if (Platform.environment['ARCHWAY_FIXTURE_VERSION'] != '2.3.4') {
      stderr.writeln('fixture route environment was not forwarded');
      exitCode = 78;
      return;
    }
    args = args.sublist(1);
  }
  final installation = File(Platform.resolvedExecutable).parent.parent.parent;
  final control = File('${installation.path}/probe-control');
  final fault = control.existsSync() ? control.readAsStringSync() : '';
  if (args.first == '--help') {
    stdout.write(
      fault == 'help'
          ? 'wrong help'
          : 'archway [--root ROOT] controlled fixture\n',
    );
    return;
  }
  if (args.first == '--version') {
    stdout.write(
      'archway ${Platform.environment['ARCHWAY_FIXTURE_VERSION'] ?? '0.1.0'}\n',
    );
    return;
  }
  final root = args[1], command = args[2];
  if (command == 'init') {
    init.main([fault == 'init' ? 'payload' : 'valid', ...args]);
    return;
  }
  if (command == 'export') {
    stdout.write('flowchart LR\n');
    stderr.writeln(jsonEncode({'exit_code': fault == 'export' ? 2 : 0}));
    return;
  }
  var code = 0;
  Object? payload = {'policy_valid': true, 'projects': 0, 'nodes': 0};
  if (command == 'check') {
    final runtime = Platform.environment['PATH']!;
    final helper = File(
      '${File(Platform.resolvedExecutable).parent.parent.parent.path}/assets/typescript/helper.cjs',
    );
    final missingNode =
        runtime.contains('no-runtime') || runtime.contains('wrong-node');
    code = args.contains('--unsupported')
        ? 64
        : missingNode || !helper.existsSync()
        ? 2
        : File('$root/src/app/main.ts').readAsStringSync().startsWith('import')
        ? 1
        : 0;
    payload = code == 64
        ? null
        : {
            'policy_valid': true,
            'analysis_complete': code != 2,
            'tool_errors': code == 2
                ? [
                    {
                      'code': missingNode
                          ? 'NODE_UNAVAILABLE'
                          : 'TYPESCRIPT_ASSETS_UNAVAILABLE',
                    },
                  ]
                : [],
            'unknowns': [],
            'observed': {'files': 2, 'analyzed_files': 2, 'edges': code},
            'violations': code == 1
                ? [
                    {'code': 'DEPENDENCY_NOT_ALLOWED'},
                  ]
                : [],
          };
  }
  if (command == 'check') {
    if (fault == 'protected-write')
      File(Platform.environment['ARCHWAY_FIXTURE_PROTECTED_FILE']!)
          .writeAsStringSync('unexpected');
    if (fault == 'project-write')
      File('$root/changed').writeAsStringSync('unexpected');
    if (fault == 'foreign-write')
      File('changed').writeAsStringSync('unexpected');
    if (fault == 'missing-helper' && code == 2)
      (payload as Map)['tool_errors'] = [];
    if (fault == 'compiler' && code == 0) (payload as Map)['observed'] = {};
  }
  exitCode = code;
  stdout.writeln(
    jsonEncode({
      'schema_version': 1,
      'command': command,
      'exit_code': fault == 'validate' && command == 'validate' ? 2 : code,
      'status': {
        0: 'ok',
        1: 'negative',
        2: 'incomplete',
        64: 'usage_error',
      }[code],
      'tool_versions': {'typescript': '5.9.3'},
      'payload': payload,
    }),
  );
}
