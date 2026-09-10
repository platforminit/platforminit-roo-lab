---
description: Run focused task validation without advancing controller state
argument-hint: <TASK-ID>
mode: platforminit-sre-diagnostics
---

Load PlatformInit MCP `get_delivery_context` for the task. Treat this command as a focused diagnostic
and validation helper, not as a second mandatory full test phase.

Run only the task's relevant required validators or the smallest reproducer needed for the current
failure. Prefer changed-path and contract-specific checks. Do not run full-repository validation,
unrelated chapter validators, infrastructure workflows, or live mutations unless the active task
explicitly requires them and human approval exists.

Reuse already passing evidence when the relevant files and inputs are unchanged. If a check fails,
return one consolidated defect/evidence batch with exact commands and affected paths. Do not change
controller state directly and do not claim review/security approval.
