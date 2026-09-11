# PlatformInit Workflow Refactor — Puma-Style Small Context

## Goal

Reduce Zoo Code token growth and HTTP 400 failures by making every lifecycle stage a fresh child,
keeping MCP payloads small, enforcing micro-task sizing, reusing unchanged evidence, and separating
n8n from the PlatformInit canonical queue.

## Required lifecycle

```text
orchestrator
  -> fresh implementation child
  -> orchestrator reloads MCP
  -> fresh review child
  -> orchestrator reloads MCP
  -> fresh OWASP child
  -> orchestrator reloads MCP
  -> fresh release child
```

No stage may depend on accumulated conversation history from a previous specialist. Handoffs contain
only task ID, stage, acceptance gaps, changed paths, evidence paths, unresolved risks, and the next
controller transition.

## Token budget

- MCP `get_delivery_context`: default max 12 changed files, hard cap 20.
- Suggested paths: max 3.
- Focused tests: max 8.
- Target task size: 1-3 primary non-state files.
- 4-5 primary files: exceptional and explicitly justified.
- More than 5 non-state files: `TASK_TOO_LARGE_SPLIT_REQUIRED`.
- Full-repository validation is forbidden by default.
- Passing unchanged evidence is reused instead of rerun.

## MCP access contract

Every PlatformInit Zoo mode must declare the `mcp` group and must be able to call `health` plus
`get_active_task` after a fresh `new_task` handoff. `.roo/commands/mcp-smoke.md` is the runtime smoke
procedure. A static validator should reject a project mode without MCP access.

## Workflow-hardening task sequence

| Task | Purpose |
|---|---|
| `P-WF-T01` | Enforce fresh-child lifecycle handoffs |
| `P-WF-T02` | Verify MCP access across every Zoo mode |
| `P-WF-T03` | Shrink MCP delivery context budget |
| `P-WF-T04` | Reuse unchanged validation evidence |
| `P-WF-T05` | Enforce micro-task sizing |
| `P-WF-T06` | Detach n8n from PlatformInit canonical task state |
| `P-WF-T07` | Create standalone n8n roadmap and task registry |
| `P-WF-T08` | Smoke-test fresh-child delivery pipeline |

These tasks run after `P-CH04.5-T02` and before `P-CH04.5-T03`.

## n8n separation

PlatformInit and n8n are separate delivery tracks, not two tracks in one lifecycle queue.

PlatformInit owns:

- `tasks/tracker.json`
- `tasks/active/**`
- `/next-task`
- PlatformInit MCP

n8n owns:

- `docs/n8n/N8N_ROADMAP.md`
- `n8n/tasks/tracker.json`
- its future dedicated next-task/controller surface

Shared infrastructure contracts may be referenced as external prerequisites, but n8n must not use
PlatformInit task IDs as mutable controller dependencies.

## Recovery on API 400

Stop the current child. Start a fresh child in the controller-selected mode, call MCP `health` and
`get_delivery_context`, and resume only from compact evidence paths. Never reconstruct the failed
conversation by rereading the repository broadly.
