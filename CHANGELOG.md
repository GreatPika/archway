# Changelog

## Unreleased

- Require Dart SDK 3.13.5.

## 0.1.0

Initial Dart-only preview release.

- Declare module ownership, public files and explicit direct dependencies in a
  version 1 architecture policy.
- Validate policies, query ownership and permissions, inspect prepared Dart
  projects, and export declared dependencies as Mermaid.
- Initialize architecture.yaml and ARCHITECTURE.md with exclusive, safe writes.
- Install the ordinary Dart executable package from the v0.1.0 Git tag using
  Dart SDK 3.13.3; bundled filesystem bridges need no user C compiler.
- Keep policy, evidence acquisition, assessment, CLI and native filesystem
  responsibilities separated by explicit acyclic Dart library imports.

This is a qualified prerelease. CI covers its actual Linux, macOS and Windows
Server hosts; the full Windows 11 desktop and prepared Flutter acceptance matrix
remains outstanding. It is not a pub.dev publication or a standalone installer.
