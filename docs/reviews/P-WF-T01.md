# P-WF-T01 Review — Enforce fresh-child lifecycle handoffs

## Verdict

**APPROVE**. The patch is limited to the three declared command definitions, is internally consistent with the canonical fresh-child rule, and provides the requested handoff/state contract without modifying product code, controller state, or release behavior.

## Scope and evidence

- Branch: `chore/p-wf-t01-workflow`.
- `git diff --name-status dev...HEAD` is empty; the worktree contains only the three declared command edits plus controller-owned generated/state files: `tasks/active/NEXT_TASK.md`, `tasks/active/platform/NEXT_TASK.md`, and `tasks/tracker.json`.
- The required `git diff --check` validator was already reported passing and was not rerun.
- No infrastructure workflow, secret, or runtime mutation was performed.

## Acceptance criteria

1. **PASS — native fresh-child lifecycle transitions.** [`next-task.md` line 17](../../.roo/commands/next-task.md:17) makes every specialist stage a native Zoo `new_task` child and explicitly forbids continuing by mode switch. [`next-task.md` lines 22–29](../../.roo/commands/next-task.md:22) defines the reload/select/start sequence and requires completion before the parent resumes. [`review-task.md` lines 14–17](../../.roo/commands/review-task.md:14) and [`submit-task.md` lines 23–26](../../.roo/commands/submit-task.md:23) remove in-place continuation and delegate fresh-child routing to the Orchestrator. This is consistent with the unchanged canonical rule in [`rules.md` lines 57–59](../../.roo/rules.md:57) and the Orchestrator mode contract in [`.roomodes` line 7](../../.roomodes:7).

2. **PASS — concise evidence plus resulting controller state and exact next transition command.** [`next-task.md` lines 25–29](../../.roo/commands/next-task.md:25) requires task-scoped handoff data and `attempt_completion` containing resulting status, exact next controller transition command, and concise evidence. [`review-task.md` lines 11–17](../../.roo/commands/review-task.md:11) requires the report/verdict workflow and the same completion payload; [`submit-task.md` lines 23–26](../../.roo/commands/submit-task.md:23) requires status, exact transition command, changed/evidence paths, and risks. The wording is operationally specific rather than a prose-only approval.

3. **PASS — MCP context reload after every child.** [`next-task.md` lines 22 and 29](../../.roo/commands/next-task.md:22) explicitly requires reload before starting each stage and after the child returns before routing again. The downstream command handoffs repeat this requirement in [`review-task.md` lines 14–17](../../.roo/commands/review-task.md:14) and [`submit-task.md` lines 23–26](../../.roo/commands/submit-task.md:23). This matches the unchanged Orchestrator instructions in [`.roomodes` line 7](../../.roomodes:7).

## Integration and regression review

- The three commands agree on the same ownership boundary: the child submits or records its result, then completes; the Orchestrator reloads authoritative MCP state and creates the next child.
- The unchanged terminal release command [`complete-task.md` lines 7–18](../../.roo/commands/complete-task.md:7) is not contradictory: it is a release/close operation after `ready_to_close`, not a specialist-stage transition, and its existing release-manager contract remains intact.
- The patch stays within the controller-reported three-file budget and does not introduce a competing task source of truth.
- The explicit exact-command requirement is appropriately enforced in `.roo/commands/**`; the rules files are outside this task's allowed implementation scope. The unchanged global and mode contracts already establish the same behavior, so no follow-up is required for this task.

## Residual risks for later stages

- Security review should independently confirm that the workflow-command wording does not cause child handoffs to expose secrets through evidence or reports.
- Release review should confirm the controller reaches the expected post-verdict state and that generated task views remain current; no release validation was performed here.
