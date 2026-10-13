# Engineering workflow

Use `mattpocock/skills@49dd158d1076134a641b33efb035946536778336`. Read the invoked skill and its relevant references from that pinned revision. Follow the [repository tracker conventions](../../AGENTS.md#issue-tracker) when adapting tool operations. Tool adaptations do not remove approval checkpoints.

## Contract first

Reuse the authoritative [repository specifications](../../AGENTS.md#read-by-task) and [versioned flat contracts](../../contracts/README.md). Read the source pointers governing the ticket; do not restart settled product design or repeat whole-project audits. Coordinate any approved CLI rename across contracts and acceptance references before coding.

## Gates

1. Complete setup review and approval before writing configuration.
2. Resolve the highest-risk compiler-integration feasibility gate before production implementation. Agree its test seams and acceptance condition, pin compiler versions, and collect reproducible evidence. Keep any spike separate from production code. Stop if the contract cannot be met.
3. Use `to-spec` to synthesize existing decisions and feasibility findings; confirm public test seams with the user.
4. Use `to-tickets` for small verifiable vertical slices and explicit blockers. Obtain approval of granularity and dependency edges before publishing or implementing.
5. Use `implement-spec` on one integration branch. Run a small bounded set of implementation agents on the ready frontier, each in an isolated branch/worktree based on that integration branch. Merge serially and verify affected checks before releasing dependent tickets.
6. Follow `tdd`: write one failing test at an approved seam, implement the minimum to pass, then repeat. Do not batch-write all new tests before implementing. Baseline and regression-suite runs remain allowed. Expected results come from independent contract evidence. Refactoring belongs to review.
7. Run separate Standards and Spec reviews against a fixed base. Repair findings, recheck, and report evidence plus unresolved release gates. Fixture validation alone does not establish compiler, platform, process, CLI, or installation acceptance.

## Bounded delegation

### Review size

Assign each reviewer at most approximately 800 lines of changed code and tests. Split larger diffs into cohesive, explicitly enumerated file or hunk ranges assigned to separate reviewers. Include necessary source context in the review budget; do not evade the limit by giving the same reviewer successive batches. Record coverage and check cross-part interfaces in bounded assignments too. Generated lockfiles and unchanged contract fixtures need provenance checks rather than line-by-line code review.

The same limit applies to final Standards and Spec review assignments; those are review tracks, not permission for one reviewer to inspect the whole package.

Before dispatch, give each worker scope, source pointers, blockers, acceptance criteria, approved seams, and a task-sized effort budget/checkpoint. At the checkpoint, return evidence and remaining work for an explicit continuation decision.

Stop dependent work on contradictory contracts, unresolved decisions, missing authorization/access, unsupported tools, failed feasibility, or an exhausted approved budget. Report the smallest actionable blocker; continue only independent authorized work. Do not respond by spawning more workers or repeating broad investigations.
