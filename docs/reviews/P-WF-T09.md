# P-WF-T09 Review — Enforce terminal specialist stages and fresh-dev startup gate

- **Task:** P-WF-T09 — Enforce terminal specialist stages and fresh-dev startup gate
- **Reviewer:** `platforminit-openai-reviewer`
- **Stage:** review re-review
- **Branch/base:** `chore/p-wf-t09-workflow` / `dev`
- **Scope:** five controller-reported non-state paths only
- **Verdict:** APPROVE

## Review basis

This re-review started from fresh controller context (`needs_review`) after the prior `REQUEST_CHANGES` verdict. It inspected only the controller-reported changed paths:

- [`.roomodes`](../../.roomodes:1)
- [`.roo/rules/05-lifecycle-routing.md`](../../.roo/rules/05-lifecycle-routing.md:1)
- [`.roo/commands/pipeline-smoke.md`](../../.roo/commands/pipeline-smoke.md:1)
- [`.roo/commands/next-task.md`](../../.roo/commands/next-task.md:1)
- [`tools/platforminit_mcp/validate_pipeline_smoke.py`](../../tools/platforminit_mcp/validate_pipeline_smoke.py:1)

The previous consolidated finding was F1: specialist mode-local contracts lacked an explicit `switch_mode` continuation prohibition and the validator did not enforce that marker. No additional implementation changes were reviewed beyond that defect batch.

## Re-review findings

### F1 — CLOSED: terminal specialist contracts and validator enforcement are load-bearing

All four specialist declarations in [`.roomodes`](../../.roomodes:20), [`.roomodes`](../../.roomodes:28), [`.roomodes`](../../.roomodes:36), and [`.roomodes`](../../.roomodes:52) now carry the normalized prohibition `never use \`switch_mode\` to continue the lifecycle`. The orchestrator declaration still states that it is the only next-stage routing owner at [`.roomodes`](../../.roomodes:7).

[`SELF_ROUTING_PROHIBITION_MARKERS`](../../tools/platforminit_mcp/validate_pipeline_smoke.py:107) now contains the same marker. [`terminal_mode_errors()`](../../tools/platforminit_mcp/validate_pipeline_smoke.py:222) consumes all self-routing markers for every specialist mode, and [`lifecycle_routing_rule_errors()`](../../tools/platforminit_mcp/validate_pipeline_smoke.py:239) consumes the shared-rule markers. The in-memory negative control removed the `switch_mode` phrase from a specialist declaration and observed the expected validator error, proving the check is load-bearing rather than incidental.

## Acceptance review

1. **Terminal specialist stages:** Satisfied. Each of the four specialist contracts declares one own-stage transition, controller recording, `attempt_completion`, termination, no nested `new_task`, no spawning, no handoff, and no `switch_mode` continuation.
2. **Orchestrator-only routing:** Satisfied. The orchestrator contract retains sole next-stage routing ownership, and the shared rule plus static validator enforce the invariant.
3. **Static versus runtime proof:** Satisfied. The smoke procedure limits automation to contract-text proof, explicitly disclaims Zoo parent/child provenance, and marks a specialist child that launches the next stage—including nested `new_task`—as a runtime failure.
4. **Fresh-dev startup gate:** Satisfied. [`.roo/commands/next-task.md`](../../.roo/commands/next-task.md:8) orders environment/tree checks, `git fetch origin`, fast-forward-only `dev` refresh, safety checks and hard-stop behavior before MCP task resolution; it forbids history rewrite and automatic dirty-work cleanup.
5. **Three existing gates and PASS lines:** Satisfied. The validator still reports exactly the three existing PASS lines for gates 1–3, and the documented gate count remains three in [`PLATFORM_WORKFLOW_REFACTOR.md`](../roo-lab/PLATFORM_WORKFLOW_REFACTOR.md:227). The new terminal-stage and startup checks extend gates 1 and 2 rather than adding a fourth gate.

## Focused evidence

- `git diff --check` passed.
- `python3 tools/platforminit_mcp/validate_pipeline_smoke.py` passed with exactly:
  - `PASS: gate 1 - 4 specialist stages route to declared fresh-child modes.`
  - `PASS: gate 2 - every stage mode boots MCP health + get_delivery_context after a handoff.`
  - `PASS: gate 3 - handoff payload bounded to 7 fields and no stale stage is routable.`
- `python3 tools/platforminit_mcp/validate_mode_access.py` passed; unchanged MCP access evidence was reused as instructed.
- In-memory negative control passed: removing the `switch_mode` marker caused [`terminal_mode_errors()`](../../tools/platforminit_mcp/validate_pipeline_smoke.py:222) to report the specialist mode.
- Direct declaration check passed for all four specialist modes and for orchestrator-only routing ownership.

## Residual risks

- [`.roomodes`](../../.roomodes:1) contract changes take effect only after the Roo host reloads custom modes.
- Static validation cannot prove Zoo parent/child runtime provenance; the manual/runtime smoke layer remains required.
- Five non-state files is at the controller warning bound and spans the workflow/agentic-lifecycle subsystem plus the startup command contract.

## Verdict transition

```bash
python3 tools/task_controller/taskctl.py review P-WF-T09 --actor platforminit-openai-reviewer --verdict approve --report docs/reviews/P-WF-T09.md
```
