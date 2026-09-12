---
description: Verify PlatformInit MCP availability after Zoo mode changes
mode: platforminit-orchestrator
---

Run this only as a lightweight workflow/tooling smoke test. Do not read the repository broadly.
It is read-only: it must not mutate runtime infrastructure, secrets, or task state.

## Automated layer (no Zoo child required)

```bash
python3 tools/platforminit_mcp/validate_mode_access.py            # static declarations
python3 tools/platforminit_mcp/validate_mode_access.py --runtime  # boots the stdio MCP server
```

Expected output (`N` = number of `platforminit-*` modes declared in `.roomodes`):

```text
PASS: N PlatformInit modes declare MCP access and required tools are enabled.
PASS: runtime MCP smoke health/get_active_task returned the authoritative PlatformInit task.
```

The static layer fails when a `platforminit-*` mode drops the `mcp` group, when its instructions stop
loading `get_delivery_context` from a fresh child, when a mode is missing from the list below, when
`.roo/commands/mcp-smoke.md` names a mode that does not exist, when `.roo/mcp.json` stops
always-allowing `health`, `get_delivery_context`, `get_active_task`, or `get_changed_scope`, or when
`tools/platforminit_mcp/server.py` stops exposing those tools. The runtime layer boots that server
over stdio JSON-RPC exactly like Zoo does and asserts `health.ok=true` plus a `get_active_task` id
that matches `tasks/tracker.json`.

## Manual per-mode layer

For each project mode below, start a fresh Zoo `new_task` child in that exact mode and require only:

1. call PlatformInit MCP `health`;
2. call `get_active_task`;
3. return `MODE`, `MCP_HEALTH`, and `ACTIVE_TASK_ID` through `attempt_completion`;
4. do not edit files or task state.

Modes:

- `platforminit-orchestrator`
- `platforminit-architect`
- `platforminit-deepseek-coder`
- `platforminit-openai-reviewer`
- `platforminit-owasp-reviewer`
- `platforminit-sre-diagnostics`
- `platforminit-release-manager`
- `platforminit-docs-operator`

PASS requires every mode to return `MCP_HEALTH.ok=true` and the same authoritative active/next
PlatformInit task ID. A missing MCP tool, stale task ID, or child that relies on inherited chat
context is FAIL. Record the command output as evidence in the active task handoff.
