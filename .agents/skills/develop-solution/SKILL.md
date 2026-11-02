---
name: develop-solution
description: Develop a minimal solution without overengineering, maximizing efficiency and preserving clean architecture within the repository context.
---

# Develop a solution

Apply this algorithm to features, bug fixes, refactors, and other changes.

1. **Ground.** Establish the requested outcome, constraints, current behavior,
   and owning boundaries from repository evidence. Delegate missing facts to
   `codebase_researcher`; bring product decisions to the user.
2. **Propose.** Compare viable approaches and choose the smallest change that
   fully solves the problem at its owning layer. Explain affected owners, reuse,
   applicable costs, compatibility, verification, and why simpler alternatives fall
   short. Tie each added abstraction or state to a concrete requirement or
   demonstrated failure.
3. **Interview.** Spawn the `griller` agent through collaboration tools.
   Supply the task, evidence paths, proposal, alternatives, assumptions,
   delegated decision authority, and readiness criteria below. Ask it to challenge
   assumptions and seek simpler or more efficient sufficient alternatives.
   You are the interviewee.
4. **Refine.** Answer each question in the round, verify disputed facts, and
   send the revised proposal to the same griller. Resolve each objection with
   a change or an evidence-backed reason to retain the design. Escalate decisions
   outside your authority to the user; continue independent branches meanwhile.
5. **Converge.** The solution is ready only when both agents substantiate all
   five criteria with repository evidence or concrete comparison:
   - **Smallest solution:** it fully solves the task, each element is necessary,
     and no considered viable approach is simpler while meeting all requirements.
   - **No overengineering:** each added abstraction, layer, dependency, or state
     addresses a current requirement or demonstrated failure.
   - **Maximum efficiency:** compare applicable costs such as execution time,
     resources, and maintenance effort; choose the most efficient viable option
     satisfying the other criteria. Measure when needed to settle a material claim.
   - **Clean architecture:** responsibilities and boundaries are respected,
     shared defects are fixed at their owner, and each fact has one source of truth.
   - **Repository context:** the design fits current requirements, architecture,
     conventions, deployment constraints, and compatibility obligations.
   Settle every decision within the agreed scope and leave no material objection
   or unsupported assumption on which the solution relies. Then confirm shared
   understanding to griller. User decisions require the user's answer;
   agent agreement cannot supply it.
6. **Deliver.** Present the final solution, evidence for each readiness criterion,
   accepted tradeoffs, and verification plan. Continue within the user's
   authorized scope using the repository's applicable implementation workflows.
