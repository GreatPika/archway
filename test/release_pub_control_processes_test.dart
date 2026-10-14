// Synthetic public examples exercise receipt semantics, not a native installation.
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/ci/release_installed_output_receipts.dart';
import '../tool/ci/release_installed_process_receipts.dart';
import '../tool/ci/release_pub_control_processes.dart';

void main() {
  test(
    'pub original controls bind SDK route, runtime and snapshot failure',
    () {
      const prefix = [
        '/sdk/dart',
        '--suppress-analytics',
        'pub',
        'global',
        'run',
        'archway:archway',
      ];
      const project = '/work/project',
          init = '/work/missing bridge init café-fixture';
      InstalledProcessEvidence row(
        List<String> args,
        int exit, {
        String out = '',
        String err = '',
      }) => (
        arguments: args,
        exitCode: exit,
        stdout: utf8.encode(out),
        stderr: utf8.encode(err),
      );
      String example(String name, String root, {String? error}) {
        final value = jsonDecode(
          File('contracts/json/fixtures/$name.json').readAsStringSync(),
        ) as Map;
        value['tool_versions']['archway'] = '2.3.4';
        value['resolved_root'] = root;
        if (error != null) {
          if (value['command'] == 'check') {
            value['status'] = 'incomplete';
            value['payload']['tool_errors'][0]['code'] = error;
            value['diagnostics'] = value['payload']['tool_errors'];
          } else {
            value['diagnostics'][0]['code'] = error;
          }
        }
        return '${jsonEncode(value)}\n';
      }

      final bridge = row(
        [...prefix, '--root', init, 'init', '--template', 'mixed'],
        2,
        out: example('init-root-access-error', init, error: 'INIT_UNAVAILABLE'),
      );
      final runtime = <InstalledProcessEvidence>[
        row(
          [
            '/runtime/node',
            '-p',
            'JSON.stringify([process.version,process.platform,process.arch])',
          ],
          0,
          out: '["v24.19.0","linux","x64"]\n',
        ),
        for (var i = 0; i < 2; i++)
          row(
            [...prefix, '--root', project, 'check'],
            2,
            out: example(
              'check-tool-error',
              project,
              error: 'NODE_UNAVAILABLE',
            ),
          ),
        row(
          [...prefix, '--root', project, 'validate'],
          0,
          out: example('validate-ok', project),
        ),
      ];
      final snapshots = <InstalledProcessEvidence>[
        row([...prefix, '--help'], 0, out: 'archway --root ROOT\n'),
        row([...prefix, '--help'], 0, out: 'archway --root ROOT\n'),
        row(
          [...prefix, '--help'],
          254,
          err: 'Error: invalid installed source\n',
        ),
        row([...prefix, '--help'], 1, err: 'Error: source cannot compile\n'),
      ];
      final snapshotCases = [
        {'case': 'poisoned-source-snapshot', 'exit': 0},
        {'case': 'stale-snapshot', 'exit': 254},
        {'case': 'missing-snapshot', 'exit': 1},
      ];
      void admit({
        InstalledProcessEvidence? initRow,
        List<InstalledProcessEvidence>? runtimes,
        List<InstalledProcessEvidence>? snapshotRows,
      }) => validatePubControlProcesses(
        bridgeInit: initRow ?? bridge,
        runtimes: runtimes ?? runtime,
        snapshots: snapshotRows ?? snapshots,
        output: InstalledOutputValidator(Directory.current, '2.3.4'),
        prefix: prefix,
        project: project,
        target: 'linux-x64',
        wrongNodeExecutable: '/runtime/node',
        snapshotCases: snapshotCases,
      );
      admit();
      final wrong = [...runtime];
      wrong[0] = row(
        runtime[0].arguments,
        0,
        out: '["v24.21.0","linux","x64"]\n',
      );
      expect(() => admit(runtimes: wrong), throwsFormatException);
      wrong[0] = runtime[0];
      wrong[2] = row(
        ['/native/archway', '--root', project, 'check'],
        2,
        out: utf8.decode(runtime[2].stdout),
      );
      expect(() => admit(runtimes: wrong), throwsFormatException);
      final stale = [...snapshots];
      stale[2] = row(snapshots[2].arguments, 0, out: 'archway --root ROOT\n');
      expect(() => admit(snapshotRows: stale), throwsFormatException);
      stale[2] = snapshots[2];
      stale[1] = row(snapshots[1].arguments, 0, out: 'changed output\n');
      expect(() => admit(snapshotRows: stale), throwsFormatException);
      expect(
        () => admit(
          initRow: row(bridge.arguments, 0, out: utf8.decode(bridge.stdout)),
        ),
        throwsFormatException,
      );
    },
  );
}
