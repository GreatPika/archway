import 'dart:convert';

import 'package:json_schema/json_schema.dart';
// Pinned json_schema 5.2.2 bundles the official metaschema but does not export it.
// Keep this internal dependency here and verify it before dependency upgrades.
import 'package:json_schema/src/json_schema/constants.dart' as bundled;

/// Draft 2020-12 validation for developer checks, not runtime policy semantics.
class ContractSchema {
  factory ContractSchema(Object? document) {
    final result = _meta.validate(document, validateFormats: true);
    if (!result.isValid) {
      throw FormatException('Invalid Draft 2020-12 schema: ${result.errors}');
    }
    _rejectEmptyEnums(document);
    return ContractSchema._(_create(document!));
  }

  ContractSchema._(this._schema);

  static final _meta = _create(
    jsonDecode(bundled.JsonSchemaDefinitions.draft2020_12),
  );

  static JsonSchema _create(Object document) => JsonSchema.create(
    document,
    schemaVersion: SchemaVersion.draft2020_12,
    refProvider: RefProvider.sync(
      (reference) => throw FormatException(
        'External schema reference is not supported: $reference',
      ),
    ),
  );

  final JsonSchema _schema;
  // json_schema 5.2.2 incorrectly treats an empty enum as unconstrained. Reject
  // this unsupported construct rather than silently accepting invalid data.
  // Only visit schema positions; const/default/examples contain instance data.
  static void _rejectEmptyEnums(Object? schema) {
    if (schema is! Map) return;
    if (schema['enum'] is List && (schema['enum'] as List).isEmpty) {
      throw FormatException('Empty enum is unsupported by json_schema 5.2.2');
    }
    for (final key in [
      r'$defs',
      'definitions',
      'properties',
      'patternProperties',
      'dependentSchemas',
    ]) {
      final children = schema[key];
      if (children is Map) children.values.forEach(_rejectEmptyEnums);
    }
    for (final key in ['allOf', 'anyOf', 'oneOf', 'prefixItems']) {
      final children = schema[key];
      if (children is List) children.forEach(_rejectEmptyEnums);
    }
    for (final key in [
      'items',
      'contains',
      'additionalProperties',
      'unevaluatedProperties',
      'unevaluatedItems',
      'propertyNames',
      'if',
      'then',
      'else',
      'not',
      'contentSchema',
    ]) {
      _rejectEmptyEnums(schema[key]);
    }
  }

  List<String> errors(Object? instance) => _schema
      .validate(instance)
      .errors
      .map((error) => error.toString())
      .toList();
}
