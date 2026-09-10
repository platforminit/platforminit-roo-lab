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

On `approve`, use a native Zoo Code handoff to the task's `securityMode`. On `request_changes`, return
one consolidated fix batch to `implementationMode`. On `block`, return to the orchestrator with the
concrete blocker.
