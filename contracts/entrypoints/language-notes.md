# Language acceptance notes

`language-acceptance.json` contains 32 unique acceptance specifications. These examples explain the normative rules in `helper/protocol.md`, `assignment/design.md`, and the entrypoint contract; they do not define an alternative policy or diagnostic ordering.

## What the examples protect

- A direct reference targets its module/library file after actual compiler file redirects. It does not target the ultimate declaration of an imported symbol. Public barrels can expose same-owner private implementations without false violations.
- Re-export references are checked individually. A foreign-private re-export fails on its own edge. A legal facade chain does not create a consumer-to-origin edge or transitive permission requirement.
- Type-only references, import-type expressions, supported literal dynamic imports, and require forms follow the same entrypoint rule. Per-occurrence import/require resolution mode matters.
- TypeScript extension substitution, package type entrypoints, and prepared project-reference redirects can select a declaration file. Public designation of a source file does not implicitly designate its declaration output.
- Dart checks every conditional URI conservatively. One unresolved branch causes incomplete analysis without erasing independently established violations. Import prefixes, combinators, and deferred loading do not change the direct file target.
- Dart parts retain physical source ownership and the existing generic part/part_of edge policy. Named part_of relationships need a uniquely established containing library. Public lists remain lexical; declaring a part public does not make an invalid standalone import valid Dart.
- Explicit TS references unsupported by the existing helper kinds, including triple-slash path/types and external-module augmentation references, require unknown/partial coverage. Script-level ambient module declarations are declarations, not themselves file references. SDK/global symbols do not trigger blanket incomplete status or symbol tracing.
- Dependency origin and physical location are different questions. Proven installed third-party dependencies remain external inside or outside the repository; workspace/project/path dependencies remain local. The compatibility acceptance cases cover this distinction separately.

The guarantee concerns explicit supported file/module references. It does not promise symbol privacy, transitive API provenance control, runtime-loader tracing, or isolation from global symbol coupling. Fixture outcomes describe semantic expectations; diagnostic presentation follows the main contract, including its principal-error precedence.

## Primary sources

- [Dart package organization, exports, parts, and conditional imports/exports](https://dart.dev/tools/pub/create-packages)
- [Dart import_of_non_library diagnostic](https://dart.dev/tools/diagnostics/import_of_non_library)
- [Dart part_of_different_library diagnostic](https://dart.dev/tools/diagnostics/part_of_different_library)
- [Analyzer LibraryImport API](https://pub.dev/documentation/analyzer/latest/dart_element_element/LibraryImport-class.html): distinguishes imported library/URI from contributed namespace.
- [Analyzer Configuration API](https://pub.dev/documentation/analyzer/latest/dart_ast_ast/Configuration-class.html): exposes each conditional URI and its nullable resolved URI.
- [TypeScript module resolution reference](https://www.typescriptlang.org/docs/handbook/modules/reference): file substitution, package type entrypoints, and resolution modes.
- [TypeScript project references](https://www.typescriptlang.org/docs/handbook/project-references.html): prepared declaration outputs and separate editor navigation behavior.
- [TypeScript 5.9.3 Program source](https://raw.githubusercontent.com/microsoft/TypeScript/v5.9.3/src/compiler/program.ts): file redirects and separate module-reference, augmentation, and ambient-declaration collections.
- [TypeScript 5.9.3 checker source](https://raw.githubusercontent.com/microsoft/TypeScript/v5.9.3/src/compiler/checker.ts): module resolution and symbol-alias resolution are distinct operations.
- [TypeScript 5.9.3 API definitions](https://raw.githubusercontent.com/microsoft/TypeScript/v5.9.3/src/compiler/types.ts): several compiler resolution helpers are internal and require pinned-version acceptance tests.

## Runtime acceptance

These are acceptance specifications, not executed compiler results. Pinned runtime/compiler acceptance is required before release. Analyzer `latest` API pages are conceptual references, not certification of the pinned analyzer build.
