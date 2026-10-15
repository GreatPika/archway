// Independent controlled process responses for the acceptance oracle, not AOT proof.
import 'dart:convert';
import 'dart:io';

void main(List<String> args) {
  final mode = args.first;
  final root = args[args.indexOf('--root') + 1];
  File('$root/architecture.yaml').writeAsStringSync(
    '# Archway: mixed template\nversion: 1\nprojects: []\nscope: []\nexclude: []\nnodes: []\n',
  );
  File('$root/ARCHITECTURE.md').writeAsStringSync(
    '# Architecture agent workflow\nInit never overwrites or merges files.\n'
    'Init does not edit AGENTS.md, CI, or editor settings.\n',
  );
  final value = <String, Object?>{
    'schema_version': 1,
    'command': 'init',
    'status': 'ok',
    'exit_code': 0,
    'diagnostics': [],
    'payload': {
      'template': 'mixed',
      'dry_run': false,
      'outcome': 'created',
      'planned_paths': ['architecture.yaml', 'ARCHITECTURE.md'],
      'planned_files': [],
      'created_paths': ['architecture.yaml', 'ARCHITECTURE.md'],
      'residual_paths': [],
      'conflicting_paths': [],
    },
  };
  switch (mode) {
    case 'exit':
      exitCode = 9;
    case 'stderr':
      stderr.write('unexpected');
    case 'envelope':
      value['command'] = 'validate';
    case 'payload':
      (value['payload'] as Map)['extra'] = true;
    case 'files':
      File('$root/extra').writeAsStringSync('extra');
    case 'policy':
      File('$root/architecture.yaml').writeAsStringSync('wrong');
    case 'guide':
      File('$root/ARCHITECTURE.md').writeAsStringSync('wrong');
    case 'guide-crlf':
      final guide = File('$root/ARCHITECTURE.md');
      guide.writeAsStringSync(
        guide.readAsStringSync().replaceAll('\n', '\r\n'),
      );
    case 'cwd':
      File('unexpected').writeAsStringSync('wrong');
    case 'bom':
      stdout.add([0xef, 0xbb, 0xbf]);
    case 'utf8':
      stdout.add([0xff]);
    case 'multiline':
      stdout.writeln();
  }
  stdout.write('${jsonEncode(value)}${mode == 'no-lf' ? '' : '\n'}');
}
