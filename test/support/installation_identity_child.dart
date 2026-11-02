import 'dart:convert';
import 'dart:io';

import '../../tool/ci/source_identity.dart';

Future<void> main(List<String> args) async {
  if (args[0] == 'source') {
    print(jsonEncode(await sourceIdentity(Directory(args[1]))));
  } else {
    print(await runtimeVersion(args[0], Directory(args[1])));
  }
}
