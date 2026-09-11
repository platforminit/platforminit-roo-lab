---
description: Review the active PlatformInit changed scope and record the controller verdict
argument-hint: <TASK-ID>
mode: platforminit-openai-reviewer
---

Require controller status `needs_review`. Load PlatformInit MCP `get_delivery_context`, then inspect
only changed files, acceptance criteria, focused evidence, and downstream consumers found through
path-scoped codebase search. Do not reread broad history or rerun unchanged full validation.

Write findings first to `docs/reviews/<TASK-ID>.md`. Record exactly one verdict through `taskctl
review`: `approve`, `request_changes`, or `block`. A prose-only verdict does not advance state.

Do not switch mode or continue review in-place. Call `attempt_completion` with the resulting controller
status, the exact next controller transition command, the report path, and unresolved risks; the
Orchestrator reloads MCP `get_delivery_context` and starts the next stage as a fresh Zoo `new_task`
child.

- On `approve`, the Orchestrator starts the task's `securityMode` as the fresh child.
- On `request_changes`, return one consolidated fix batch for a fresh `implementationMode` child.
- On `block`, return to the orchestrator with the concrete blocker.
