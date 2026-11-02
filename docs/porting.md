# Archway as an architectural reference

Dart is the only implemented analysis language. Future language ports are a
separate project, not dormant adapters or a plugin framework in this one.

## Preserve behavior, replace mechanisms

- **Plan** is the portable policy model (separate from its filesystem/YAML loader): lexical paths, ownership, direct allows,
  exact public entrypoints, diagnostics and deterministic declared graph.
- **Inspection** defines evidence and orchestration: independent corpus,
  unique project/context assignment, reliable facts, uncertainty and final input
  revalidation. A port replaces Dart analyzer/package/SDK discovery with its
  language's actual resolver, not guessed imports or filenames.
- **CLI** preserves grammar, complete JSON schema, exit/status precedence,
  deterministic ordering and Mermaid escaping.
- **Bootstrap/native I/O** preserves no-overwrite, exclusive opened handles,
  no-follow identity checks and precise partial/residual outcomes. Platform
  implementation may differ; do not replace safety guarantees with convenience.

The boundary is facts versus policy: the resolver reports a direct target and
its evidence; Plan decides permission. A language port must retain this boundary
without copying the analyzer's internal types into the policy model.

## Conformance before expansion

Start with `contracts/json`, the assignment/path reference cases and the linked
entrypoint oracle. Their Dart validators are executable reference implementations,
not a requirement that a port use Dart. Neutral sample paths can end in `.ts` or
have no extension: policy-only queries deliberately do not infer a language.

Finite fixtures are necessary, not proof of integration. Add real compiler,
package provenance, alias, failure and installed-route tests on the port's target
platforms. Preserve independent violations when other evidence is incomplete.
A green check is bounded architecture evidence, never application correctness.

Keep the existing four owners. Do not introduce a registry, cross-language base
class, catch-all model package, generic service layer or new public embedding API
until an actual second implementation demonstrates a concrete need.


The implementation is also a reference for dependency direction: pure policy
values and queries, factual compiler evidence, policy assessment, and transport
have explicit acyclic imports. See the [internal library map](spec/architecture.md#internal-libraries).
Port the behavior and these responsibilities rather than copying a Dart-specific
shared private namespace or manufacturing interfaces for nonexistent adapters.
