# Archway v1 acceptance

Acceptance fixtures define expected behavior; they are not evidence of recorded Archway execution.

## Ordered gates

1. Pin the declared dependencies and verify their availability. Before production expansion, complete the **compiler-host feasibility gate** on small real projects: positive reads, negative probes and directory inventories; every supported Dart conditional URI branch; analyzer contexts; propagation to input identity and independent final revalidation. If trustworthy tracing cannot be achieved, stop dependent implementation and request a supported-boundary decision. A finite model cannot pass this gate.
2. Confirm the four [module test seams](architecture.md#existing-test-interfaces) and the vertical-slice dependency plan before implementation.
3. Deliver a thin query/check path through one Plan predicate, the independent corpus, the real Dart adapter, coverage, identity and complete JSON. Demonstrate a known violation surviving simultaneous unknown evidence.
4. Complete the other commands and semantic invariants, runtime faults, safe initialization and Mermaid behavior.
5. Install the ordinary Dart package and run complete acceptance in each clean target environment.

## Seam coverage and its limits

| Seam | Must catch | Does not establish alone |
| --- | --- | --- |
| loadPlan and returned Plan queries | YAML/parser errors; empty plan; portable lexical paths; future overlaps; required public; direct versus transitive permission; owned/excluded/outside/unowned; sealed modules; exact pointers; catalogue/pagination/hash | Compiler extraction, physical target identity, process behavior or installed executable |
| Inspection.check on real projects | Corpus independent of compiler exclusions; zero/multiple/unknown contexts; unsupported kinds; final compiler targets; provenance; boundary precedence; public/re-export/parts/conditional branches; stable identity and input conflicts; known violations retained under incompleteness | CLI argument/stream contract and target OS coverage unless executed there |
| Bootstrap.initialize with temporary roots | Exactly two files; dry-run contents; preflight conflicts; exclusive-create race; second-write failure; no automatic deletion; residual paths include replacements and uncertain observations | Transactional two-file creation, which is not promised; all platform filesystem semantics |
| CLI.run with captured streams | Grammar and options; complete deterministic JSON; status/exit precedence; clean stdout/stderr; help/version; declared safe Mermaid; command routing with the same predicates | Packaged AOT asset lookup, external-runtime discovery, actual process cleanup or clean-machine installation |

Fault-test dependencies exercise failure behavior through these seams. Real compiler, process, platform and installed-package runs are additional acceptance evidence, not substitute mocks or new public interfaces.

## Required evidence families

- Public schema plus semantic checks: all positive/negative fixtures, sorting, deduplication, exact-byte policy hash, references, range order, count arithmetic, candidate/descriptors, status/exit mapping, public-node detail, linked policy/edge predicates and independent policy/result versions.
- Real Dart: prepared contexts/workspaces/nested packages; every supported conditional branch; import/export/part/part-of; missing inputs; Flutter import/dart:ui/parts/generated imports/cache absence. Retain physical source owners and independent facts.
- Physical paths/provenance: symlink/junction refusal in corpus, supported resolver aliases, canonical containment, Unicode/case collisions, unchanged hardlink path semantics, installed versus repository/path provenance, missing/contradictory lock joins and real package-manager fixtures.
- Revalidation: changed bytes, absent target appearance, changed inventories, alias retargeting, cross-project contradictory observations, invalidation of affected facts and discovery while preserving independent violations. Empty/partly inaccessible corpus cannot claim false success.
- Runtime: missing/wrong SDK or native asset, bounded preflight output, timeout/cancellation, exit plus EOF, bounded reap, and stopping later launches when termination is unconfirmed. Preserve independent project evidence.
- Init/export: no implicit overwrite, fixed filenames, template comments only, `init --policy` fails before writes, precise planned/created/residual/conflict outcomes, safe Mermaid text and deterministic complete output with separate diagnostics.

Use the [contract route table](../../contracts/README.md) to select exact fixture sets; language and adversarial acceptance JSON are scenarios to execute against the implementation, not proof they already ran.

## Required release matrix

A fully validated stable release requires every cell below to install and run
the actual Dart package in a clean machine/VM. A qualified prerelease may expose
the tested package before this matrix is complete only when its release notes
name actual tested hosts and outstanding cells; prerelease publication does not
mark these required stable-acceptance gates passed:

- linux-x64: Ubuntu 24.04 LTS, glibc.
- macos-arm64: macOS 15, APFS.
- windows-x64: Windows 11 24H2, NTFS.

Use foreign cwd and Unicode/spaced paths, actual writes, prepared Dart/Flutter
fixtures, aliases, runtime/fault cases and no project-code execution. A bundled
asset or server CI pass is not desktop-platform certification. Record real passes,
failures and skips separately; never silently certify an unrun cell.

## Required package-route acceptance

Follow [delivery](../../contracts/compatibility/delivery.md): actual standard Git
install, update to another revision, reinstall and uninstall; installed init,
query, prepared link-bearing check and export with original source unavailable
and no Node/C compiler on PATH. Missing/wrong ABI assets in isolated test copies
must fail closed. The hook selects assets; it must not download or compile.

Local Git installation proves SDK packaging, not remote hosted availability.
After authorized branch publication verify the exact remote install command.
Remote publication, release and registry upload require their own authorization;
local tests do not authorize them. `publish_to: none` remains set for this Git-distributed package.

## Scope boundaries

No hierarchy, HTML viewer/editor, symbol/dataflow control, new language, multiple assigned contexts per file, persistent inspection/result cache, daemon/server, MCP, plugin system, public embedding API, brew installer, custom dependency/bootstrap installer, automatic AGENTS/CI/editor changes, or automatically weakened policy. Application tests remain separate from architecture checks.
