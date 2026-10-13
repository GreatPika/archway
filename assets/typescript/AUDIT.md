# TypeScript compiler evidence and tracing boundary

## Version and evidence boundary

The compiler source references below apply to the official TypeScript 5.9.3 npm
package pinned in this directory's lockfile and bundled at
`vendor/typescript/lib/typescript.js`, SHA-256
`3ae902c92cc44dace175c0e69e13a4b0899f6983c6121d76b9ab8dd5795e7675`.
The runtime is Node 24.21.0. See [README.md](README.md) for preparation instructions.
These source observations support the bounded helper implementation. They do not
certify platform or release-installation matrices. Current reference and package
acceptance boundaries are in the
TypeScript inspection guide (source-checkout-only repository-root path:
`docs/implementation/typescript-packages.md`).

## Compiler routes observed

- Config and extends: config entry `42465–42490`, extended config reads `43641`.
- Compiler source host: `126210–126229`, `126251–126290`; source text flows from
  `system.readFile`, without a second Program or forced corpus root names.
- Node System stat: `8404–8410`. Permission and other nonabsence errors swallowed
  by TypeScript remain explicit trace errors in the helper.
- Raw file bytes and BOM decoding: `8525–8548`.
- Immediate unfiltered directory entries: `8570–8590`. Compiler recursive/filter
  output is not substituted for the consulted directory inventories.
- `readDirectory` supplies a lexical realpath callback at `8593–8597`.
- Native realpath is captured at `8281`, used at `8623–8631`.
- Initial filesystem case sensitivity: `8277`, `8483–8493`. Instrumentation is
  installed before compiler loading, covering its swapped-case filename probe.
- Default host tracing writes to stdout at `126284`. The helper routes this
  diagnostics-only callback to stderr, preserving valid compiler options.
- Program import processing: `128929–128975`.
- Module-string symbol lookup: `91951–91958`, then `54008–54155`. The helper takes
  the symbol's SourceFile declaration and never follows an imported binding's
  symbol alias to an implementation behind a barrel.
- Source project-reference redirects require an explicit positive host callback
  at `127071`; the standard helper host does not provide that callback.

The pinned Node System has no asynchronous read route in this analysis path.
Other filesystem operations are directory creation (`8331`), CPU-profile writes
(`8467–8470`), watchers (`8496–8519`), emit writes (`8556–8566`), timestamp mutation
(`8645`), and deletion (`8652`). Config parsing plus `createProgram` does not call
those routes. The helper does not call emit, watch, profiler or CLI execution;
its host write callback rejects writes. It does not invoke `sys.require`, package
managers, hooks, project compiler code, or network APIs.

## Byte and identity handling

The observer hashes the Buffer returned by each source read before TypeScript
can mutate it during UTF-16BE decoding. Node's compiler-module loader requests
UTF-8 strings; its read uses one Buffer read, records those bytes, then decodes
that same Buffer. It does not hash a re-encoded string or reread for the hash.

Source verification matches TypeScript's UTF-8 BOM removal and UTF-16LE/BE BOM
handling, including odd UTF-16 byte truncation. Malformed UTF-8 source evidence
is rejected conservatively. Parent span validation must agree with the supported
source decoding or explicitly report unsupported encoding. Positions use the
Program SourceFile's UTF-16 line/column API and the full declaration extent.

Inventories hash compact JSON immediate entry tuples sorted by Unicode code
point. Repeated identical observations share IDs; conflicting observed identity
or bytes retain distinct input records. Aliases retain observed/canonical URIs,
including observed symlink ancestor mappings. The parent independently checks
all observations, including conflicts and negative probes; no snapshot is claimed.

## Observation guards and remaining limits

Operation/result guards compare successful stat/lstat types, file reads,
directory enumeration and realpath results with their recorded observations.
Symlink lstat results are separately verified without confusing link and target
types. Negative existsSync results require a confirming stat so permission errors
cannot be recorded as absence. Disagreement emits a trace error; this does not
claim atomicity or detect a change-and-revert race.

Package, self-reference and Node ambient proofs use private protocol v2 and the
static modules described in [README.md](README.md). Actual final Program
source/declaration targets are retained; require-mode resolution never adds a
Program root. Parser reads and positive/negative metadata probes use the same
traced filesystem routes. The local fallback checks the final SourceFile,
package ID, resolvedFileName and originalPath; package-manager aliases require a
supported provenance join rather than path-only local classification.

A malformed target encoding can reach the project-level failure catch.
Independent facts already recorded survive, but later unrelated files may not
be analyzed. Ambient virtual module imports still need a physical/proven target
and otherwise stay unresolved. Unsupported package joins remain unknown; the
inspection guide (source-checkout-only repository-root path:
`docs/implementation/typescript-packages.md`) documents supported metadata and require forms without claiming artifact authentication.
