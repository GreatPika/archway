# Language acceptance notes

`language-acceptance.json` contains Dart acceptance specifications. These examples explain the normative rules in `assignment/design.md`, and the entrypoint contract; they do not define an alternative policy or diagnostic ordering.

## What the examples protect

- A direct reference targets its module/library file after actual compiler file redirects. It does not target the ultimate declaration of an imported symbol. Public barrels can expose same-owner private implementations without false violations.
- Re-export references are checked individually. A foreign-private re-export fails on its own edge. A legal facade chain does not create a consumer-to-origin edge or transitive permission requirement.
- Dart checks every conditional URI conservatively. One unresolved branch causes incomplete analysis without erasing independently established violations. Import prefixes, combinators, and deferred loading do not change the direct file target.
- Dart parts retain physical source ownership and the existing generic part/part_of edge policy. Named part_of relationships need a uniquely established containing library. Public lists remain lexical; declaring a part public does not make an invalid standalone import valid Dart.
- Dependency origin and physical location are different questions. Proven installed third-party dependencies remain external inside or outside the repository; workspace/project/path dependencies remain local. The compatibility acceptance cases cover this distinction separately.

The guarantee concerns explicit supported file/module references. It does not promise symbol privacy, transitive API provenance control, runtime-loader tracing, or isolation from global symbol coupling. Fixture outcomes describe semantic expectations; diagnostic presentation follows the main contract, including its principal-error precedence.

## Primary sources

- [Dart package organization, exports, parts, and conditional imports/exports](https://dart.dev/tools/pub/create-packages)
- [Dart import_of_non_library diagnostic](https://dart.dev/tools/diagnostics/import_of_non_library)
- [Dart part_of_different_library diagnostic](https://dart.dev/tools/diagnostics/part_of_different_library)
- [Analyzer LibraryImport API](https://pub.dev/documentation/analyzer/latest/dart_element_element/LibraryImport-class.html): distinguishes imported library/URI from contributed namespace.
- [Analyzer Configuration API](https://pub.dev/documentation/analyzer/latest/dart_ast_ast/Configuration-class.html): exposes each conditional URI and its nullable resolved URI.

## Runtime acceptance

These are acceptance specifications, not executed compiler results. Pinned runtime/compiler acceptance is required before release. Analyzer `latest` API pages are conceptual references, not certification of the pinned analyzer build.
