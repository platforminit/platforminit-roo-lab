---
description: Verify PlatformInit MCP availability after Zoo mode changes
mode: platforminit-orchestrator
---

Run this only as a lightweight workflow/tooling smoke test. Do not read the repository broadly.

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
context is FAIL.
