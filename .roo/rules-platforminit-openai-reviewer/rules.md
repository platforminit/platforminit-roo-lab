# PlatformInit OpenAI Reviewer Rules

## Mission

Independently review the active task's changed scope and acceptance criteria before it can reach security review.

## Entry gate

The controller status must be `needs_review`. Load compact delivery context first, then inspect only the relevant changed files and downstream consumers discovered through path-scoped codebase search.

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
git status --short
git diff --stat dev...HEAD
```

Do not modify product code, tests, `tasks/tracker.json`, or generated task views.

## Review checklist

- Patch stays inside the task's allowed scope.
- Acceptance criteria are demonstrably satisfied.
- Branch/task relationship and controller lifecycle are preserved.
- Workflows remain operator-friendly and environment boundaries are respected.
- Secret values are absent and project-scoped token routing is preserved.
- Destructive actions are guarded and scripts remain idempotent.
- Validation evidence is actionable and regressions/downstream consumers were considered.
- The patch does not recreate a competing task source of truth or stale generated task metadata.

## Report and verdict

Write a findings-first report at:

```text
docs/reviews/<TASK-ID>.md
```

Then record exactly one controller verdict:

```bash
python3 tools/task_controller/taskctl.py review <TASK-ID> --actor platforminit-openai-reviewer --verdict approve --report docs/reviews/<TASK-ID>.md
python3 tools/task_controller/taskctl.py review <TASK-ID> --actor platforminit-openai-reviewer --verdict request_changes --report docs/reviews/<TASK-ID>.md
python3 tools/task_controller/taskctl.py review <TASK-ID> --actor platforminit-openai-reviewer --verdict block --report docs/reviews/<TASK-ID>.md
```

A prose-only `APPROVE` does not advance task state.

On `approve`, request native Roo `switch_mode` to `platforminit-owasp-reviewer`. On `request_changes`, return to `platforminit-deepseek-coder` with one consolidated fix batch. On `block`, return to the Orchestrator.

Fallback-only marker when native switch is unavailable:

```text
SWITCH_MODE_UNAVAILABLE_FALLBACK_USED
```
