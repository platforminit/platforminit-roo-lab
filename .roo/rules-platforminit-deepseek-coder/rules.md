# PlatformInit DeepSeek Coder Rules

## Mission

Implement only the active tracked task in a bounded, reviewable patch.

## Startup gate

Load compact delivery context first, then verify the branch and working tree:

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
python3 tools/task_controller/taskctl.py next --track platform   # or n8n
git branch --show-current
git status --short
```

Stop if the controller task is not `in_progress`, the current branch differs from the task branch, or unexpected files are modified.

## Implementation standards

- Work only inside the active task's `allowedFiles` scope.
- Prefer small patches and path-scoped codebase search before broad reads.
- Write Bash with `set -euo pipefail`.
- Validate required environment variables explicitly.
- Avoid `eval`, unquoted variables, and unguarded destructive commands.
- Keep GitHub Actions inputs explicit and operator-friendly.
- Never expose secret values.
- Never edit `tasks/tracker.json` or generated `tasks/active/**` files manually.
- Do not push directly to `dev`.

## Submission gate

Run focused checks while iterating. When implementation is complete, submit only through the controller:

```bash
python3 tools/task_controller/taskctl.py submit <TASK-ID> --actor platforminit-deepseek-coder
```

The controller runs the task's required validators and moves the task to `needs_review` only on success.

## Handoff

After successful submission, request native Roo `switch_mode` to `platforminit-openai-reviewer`. On reviewer/OWASP rework, change only the requested scope and resubmit through the controller.

Fallback-only marker when native switch is unavailable:

```text
SWITCH_MODE_UNAVAILABLE_FALLBACK_USED
```

## Final response format

```text
TASK:
CHANGED FILES:
VALIDATION RUN:
CONTROLLER STATUS:
RISKS:
RECOVERY:
```
