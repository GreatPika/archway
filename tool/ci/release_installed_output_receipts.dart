// Public result schemas and original stream semantics shared by installed routes.
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../validation/json_schema.dart';
import 'release_execution_receipts.dart';
import 'release_installed_process_receipts.dart';
import 'release_receipt_values.dart';

final class InstalledOutputValidator {
  InstalledOutputValidator(Directory repository, this.version)
    : _schemas = {
        for (final name in ['public-result', 'export-diagnostics'])
          name: ContractSchema(
            readRecord(
              File(
                p.join(
                  repository.path,
                  'contracts',
                  'json',
                  '$name.schema.json',
                ),
              ),
            ),
          ),
      };
  final String version;
  final Map<String, ContractSchema> _schemas;

  Map<String, dynamic> _result(
    List<int> bytes,
    String schema,
    String? command,
    int code,
    String status,
    String? error,
  ) {
    requireReceipt(
      bytes.isNotEmpty &&
          bytes.last == 10 &&
          bytes.where((byte) => byte == 10).length == 1,
      'Installed result must be one original JSON line',
    );
    final value = receiptObject(decodeEvidenceJson(utf8.decode(bytes)));
    requireReceipt(
      _schemas[schema]!.errors(value).isEmpty &&
          value['command'] == command &&
          exactReceipt(value['exit_code'], code) &&
          value['status'] == status &&
          receiptObject(value['tool_versions'])['archway'] == version,
      'Installed result schema/version/command/status differs',
    );
    if (error != null) {
      final errors = receiptList(
        command == 'check'
            ? receiptObject(value['payload'])['tool_errors']
            : value['diagnostics'],
      );
      requireReceipt(
        exactReceipt(errors.map((row) => receiptObject(row)['code']).toList(), [
          error,
        ]),
        'Installed result error code differs',
      );
    }
    return value;
  }

  Map<String, dynamic> publicResult(
    InstalledProcessEvidence process, {
    required String? command,
    required int code,
    required String status,
    String? error,
    bool? analysisComplete,
  }) {
    requireReceipt(
      process.exitCode == code && process.stderr.isEmpty,
      'Installed public exit or stderr differs',
    );
    final value = _result(
      process.stdout,
      'public-result',
      command,
      code,
      status,
      error,
    );
    if (analysisComplete != null) {
      requireReceipt(
        receiptObject(value['payload'])['analysis_complete'] ==
            analysisComplete,
        'Installed analysis completeness differs',
      );
    }
    return value;
  }

  Map<String, dynamic>? exportResult(
    InstalledProcessEvidence process, {
    required int code,
    required String status,
    String? error,
    bool fileOutput = false,
    bool allowEmptySuccess = false,
  }) {
    requireReceipt(
      process.exitCode == code && (!fileOutput || process.stdout.isEmpty),
      'Installed export exit or stdout differs',
    );
    if (allowEmptySuccess && code == 0 && process.stderr.isEmpty) return null;
    return _result(
      process.stderr,
      'export-diagnostics',
      'export',
      code,
      status,
      error,
    );
  }
}
