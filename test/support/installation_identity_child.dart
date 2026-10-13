import 'dart:convert';
import 'dart:io';

import '../../tool/release/installation_identity.dart';

Future<void> main(List<String> args) async {
  if (args[0] == 'source-without-git-dir') {
    final environment = {...Platform.environment}..remove('GIT_DIR');
    print(
      jsonEncode(
        await sourceIdentity(Directory(args[1]), environment: environment),
      ),
    );
  } else {
    print(await runtimeVersion(args[0], Directory(args[1])));
  }
}
