import 'dart:io';

import 'package:archway/src/inspection/inspection.dart';
import 'package:archway/src/plan/plan.dart';
import 'package:test/test.dart';

import 'dart_inspection_test.dart' show dartFixture;

void main() {
  test('inactive conditional file-URI closure participates in named-part uniqueness', () async {
    final root = await dartFixture();
    final outside = await Directory.systemTemp.createTemp(
      'archway-owner-closure-',
    );
    addTearDown(() => outside.delete(recursive: true));
    final part = File('${root.path}/lib/core/private.dart');
    await part.writeAsString('part of named_app; class Thing {}');
    await File('${root.path}/lib/core/fallback.dart')
        .writeAsString('class Fallback {}');
    await File('${outside.path}/bridge.dart')
        .writeAsString("export 'owner.dart';");
    await File('${outside.path}/owner.dart')
        .writeAsString("library named_app; part '${part.uri}';");
    await File('${root.path}/lib/app/main.dart').writeAsString(
      "library named_app; export '../core/fallback.dart' if (dart.library.html) '${File('${outside.path}/bridge.dart').uri}'; part '../core/private.dart';",
    );
    final report = await Inspection().check(RepositorySelection(root.path));
    expect(report.status, 'incomplete');
    final edges = (report.payload['facts'] as Map)['edges'] as List;
    expect(edges.singleWhere((e) => e['kind'] == 'part_of')['resolution'], {
      'kind': 'unresolved',
    });
    expect(
      edges.singleWhere((e) => e['kind'] == 'part')['resolution']['path'],
      'lib/core/private.dart',
    );
    final inputs = (report.payload['input_identity'] as Map)['inputs'] as List;
    expect(
      inputs.any(
        (i) =>
            i['location']['canonical_file_uri'] ==
            File('${outside.path}/owner.dart').uri.toString(),
      ),
      true,
    );
  });
}
