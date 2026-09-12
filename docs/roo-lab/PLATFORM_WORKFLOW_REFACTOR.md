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

- MCP `get_delivery_context`: default 5 changed files, hard cap 8. The cap is both advertised in the
  tool schema and enforced by the shipped handler, so a large `maxFiles` request is clamped.
- Suggested paths: removed. The compact payload no longer duplicates them; use the task's own
  `allowedFiles`.
- Focused tests: max 3.
- Target task size: 1-3 primary non-state files.
- 4-5 primary files: exceptional and explicitly justified.
- More than 5 non-state files: `TASK_TOO_LARGE_SPLIT_REQUIRED`.
- Full-repository validation is forbidden by default.
- Passing unchanged evidence is reused instead of rerun.

## Delivery context contract (contextVersion 3)

`get_delivery_context` returns exactly these top-level fields and nothing else:

| Field | Content |
|---|---|
| `contextVersion` | `3` — bumped when the compact payload shape changes |
| `project` | `platforminit` |
| `track` | `platform` — the only track this MCP serves |
| `task` | active task summary: `id`, `track`, `status`, `title`, `scope`, `branch`, `dependsOn`, `acceptanceCriteria`, `allowedFiles`, `requiredValidators`, `forbiddenActions`, `stage`, `nextMode`, `command` |
| `scope` | bounded changed scope: `base`, `platformOnly`, `fileCount`, `files`, `truncated`, `focusedTests`, `foreignPathsExcluded`, `budget` |
| `handoff` | `payload` list only: task id, stage, acceptance gaps, changed paths, evidence paths, unresolved risks, controller transition |
| `authoritativeTaskSource` | `tasks/tracker.json` |

Removed from the payload on purpose: the prose `handoff.rule` string, the `indexing` block, and the
duplicated `suggestedPaths`. Those rules belong to this document, not to every MCP response. When no
platform task is runnable the `task` field carries a `state` marker (`no-runnable-platform-task`, or
`unknown-platform-task` for a task ID that is not a platform task) instead of a full summary.

Platform-only rules:

- task selection reads only `track == "platform"` entries; no other track is ever selected, summarised,
  or routed;
- `scope.platformOnly` is always `true` and `foreignPathsExcluded` counts paths owned by the separate
  n8n track (`n8n/`, `docs/n8n/`) that were deliberately dropped from the window;
- controller-owned state (`tasks/tracker.json`, `tasks/active/`, review and security-review reports)
  stays excluded from the changed scope.

## MCP access contract

Every PlatformInit Zoo mode must declare the `mcp` group and must be able to call `health` plus
`get_active_task` after a fresh `new_task` handoff. `.roo/commands/mcp-smoke.md` is the smoke
procedure and documents both layers:

- static: `python3 tools/platforminit_mcp/validate_mode_access.py` rejects a `platforminit-*` mode
  without the `mcp` group, without a fresh-child `get_delivery_context` bootstrap, missing from the
  smoke procedure, or backed by MCP config/server that no longer exposes the required tools. It also
  rejects a soft changed-scope hard cap, a non-default clamp fallback, a `maxFiles` schema that does
  not advertise the small-task bound, or a non-platform delivery track;
- runtime: `python3 tools/platforminit_mcp/validate_mode_access.py --runtime` boots the stdio server
  and proves `health` plus `get_active_task` return the authoritative tracker task, that
  `get_delivery_context` holds only the contract fields above, and that an oversized
  `get_changed_scope` request is still clamped to the hard cap.

A mode change is only valid when MCP state is re-derived from the controller after the handoff, so no
specialist stage depends on conversation-carried context.

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

PlatformInit and n8n are separate delivery tracks, not two tracks in one lifecycle queue. The
PlatformInit MCP therefore contains no project/track branching: it serves the platform queue only and
removes n8n-owned paths from the changed-scope window (`foreignPathsExcluded`) instead of duplicating
n8n task state or n8n routing inside PlatformInit.

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
