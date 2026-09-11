# PlatformInit DeepSeek Coder Rules

## Mission

Implement only the active PlatformInit task in a bounded, reviewable patch.

## Startup gate

As a fresh Zoo child, call MCP `health` then `get_delivery_context`. Verify WSL, exact task branch, and working tree. Stop if task status is not `in_progress`, branch mismatches, or unexpected files are modified.

## Implementation standards

- Work only inside `allowedFiles`.
- Target 1-3 primary non-state files; 4-5 is exceptional; above 5 => `TASK_TOO_LARGE_SPLIT_REQUIRED`.
- Use path-scoped codebase search before broad reads.
- Run focused validators/tests only; never full-repo validation unless explicitly required or invalidated by changed shared dependencies.
- Reuse unchanged passing evidence.
- Never expose secret values or edit tracker/generated views manually.
- Never push directly to `dev`.

## Submission gate

Submit only through:

```bash
python3 tools/task_controller/taskctl.py submit <TASK-ID> --actor platforminit-deepseek-coder
```

After submission, do not switch role in-place. Call `attempt_completion` with:

- task ID;
- resulting controller status;
- changed paths;
- focused tests/validators and evidence paths;
- decisions;
- unresolved risks.

The Orchestrator starts the reviewer as a new child after reloading MCP context. Reviewer/OWASP rework also returns as a fresh implementation child with one consolidated defect batch.
