---
description: Smoke-test the fresh-child delivery pipeline end to end
mode: platforminit-orchestrator
---

Run this only as a workflow/tooling smoke test. Do not read the repository broadly. It is read-only: it
must not run infrastructure workflows and must not mutate runtime infrastructure, secrets, GitHub
environments, or task state.

## Acceptance gates

| Gate | Acceptance criterion | PASS condition |
|---|---|---|
| G1 | fresh child is used for every specialist stage | every stage runs as a separate fresh Zoo `new_task` child in the controller-returned mode |
| G2 | MCP context is available after each handoff | every stage child answers MCP `health` and `get_delivery_context` at child start |
| G3 | handoff payload remains bounded and no stale stage is executed | every handoff carries only the seven bounded fields, and routing uses the reloaded authoritative status only |

## Automated layer (no Zoo child required)

```bash
python3 tools/platforminit_mcp/validate_pipeline_smoke.py     # gates G1-G3, contract level
python3 tools/platforminit_mcp/validate_mode_access.py --runtime  # reused: get_delivery_context after handoff
```

The second command is the unchanged MCP-access runtime evidence from the MCP access contract; reuse it
instead of rerunning it when its scope did not change.

Expected output of `validate_pipeline_smoke.py`:

```text
PASS: gate 1 - 4 specialist stages route to declared fresh-child modes.
PASS: gate 2 - every stage mode boots MCP health + get_delivery_context after a handoff.
PASS: gate 3 - handoff payload bounded to 7 fields and no stale stage is routable.
```

The contract layer fails when a lifecycle status has no stage, when a stage maps to a mode that is not
declared in `.roomodes` or not documented below, when a stage mode drops the `mcp` group or its
fresh-child `health`/`get_delivery_context` bootstrap, when the handoff payload drifts from the seven
bounded fields, when an unknown task id or an unmapped status still yields a routable stage, or when
[`next-task.md`](next-task.md:15) loses the fresh-child routing contract.

## Manual per-stage layer

Every stage must be started as one fresh Zoo `new_task` child in the mode the controller returns
(`nextMode`), never by switching mode inside an accumulated conversation.

| Stage (controller status) | Tracker role field | Expected mode |
|---|---|---|
| implementation (`in_progress`) | `implementationMode` | `platforminit-deepseek-coder` |
| review (`needs_review`) | `reviewMode` | `platforminit-openai-reviewer` |
| security-review (`needs_security_review`) | `securityMode` | `platforminit-owasp-reviewer` |
| release (`ready_to_close`) | `releaseMode` | `platforminit-release-manager` |

For each stage:

1. Reload MCP `get_delivery_context` in the orchestrator and take the returned `stage`, `nextMode`, and
   transition command as authoritative.
2. Start exactly one fresh Zoo `new_task` child in that `nextMode`.
3. Require the child to call MCP `health` then `get_delivery_context` at child start, and to return
   `MCP_HEALTH`, `STAGE`, `NEXT_MODE`, and the exact controller transition command.
4. Discard the child conversation context when it returns; reload `get_delivery_context` before routing
   again. Route only from authoritative status (`in_progress` -> `implementationMode`, `needs_review` ->
   `reviewMode`, `needs_security_review` -> `securityMode`, `ready_to_close` -> `releaseMode`,
   `blocked`/`done` -> stop).

Handoff contract: each handoff carries only the seven bounded fields — task id, stage, acceptance gaps,
changed paths, evidence paths, unresolved risks, and the controller transition. Nothing else is passed
between stages: no prose rules, no indexing hints, no suggested paths, and no inherited chat history.

## FAIL conditions

- a stage is executed by switching mode instead of a fresh Zoo `new_task` child;
- a child cannot answer MCP `health` or `get_delivery_context` after the handoff, or reports a different
  active task id than the reloaded controller context;
- a handoff carries fields beyond the seven bounded ones, or reuses changed paths and evidence paths
  remembered from a previous stage instead of the reloaded `get_delivery_context`;
- a stage is routed from a remembered status instead of the reloaded authoritative status, or a
  `blocked`/`done` task is routed into a specialist stage.

PASS requires every stage above to satisfy G1-G3 and the automated layer to pass. Record the exact
commands and their observed output as evidence in the active task handoff.
