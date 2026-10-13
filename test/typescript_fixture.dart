import 'dart:io';

import 'inspection_test.dart' as base;

Future<Directory> fixture({
  String? config,
  String? main,
  String? policy,
}) async {
  final root = await base.fixture(config: config, main: main, policy: policy);
  // Bound Node16/NodeNext package-scope discovery to this fixture. Sibling
  // temporary repositories are not compiler inputs of this prepared package.
  await File('${root.path}/package.json').writeAsString('{"type":"commonjs"}');
  return root;
}
