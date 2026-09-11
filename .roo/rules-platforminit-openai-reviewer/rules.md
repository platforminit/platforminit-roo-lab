# PlatformInit OpenAI Reviewer Rules

## Mission

Independently review the active task's changed scope and acceptance criteria before security review.

## Entry gate

Run only as a fresh Zoo child when controller status is `needs_review`. Call MCP `health` then `get_delivery_context`. Do not inherit implementation conversation history and do not reread broad roadmap/history unless compact evidence is missing.

Inspect only changed files plus directly affected consumers found through path-scoped search. Do not modify product code, tests, tracker state, or generated task views.

## Review checklist

- Patch stays inside allowed scope and micro-task budget.
- Acceptance criteria are demonstrably satisfied.
- Branch/task/controller lifecycle is preserved.
- Operator UX/environment boundaries remain correct.
- Secret values are absent and destructive actions are guarded.
- Scripts remain idempotent where required.
- Focused validation evidence is sufficient and unchanged PASS evidence is reused.
- No competing task source of truth or stale generated state is introduced.

Return all defects in one consolidated batch.

## Report and verdict

Write `docs/reviews/<TASK-ID>.md`, then record exactly one controller verdict with `taskctl review`.
A prose-only approval does not advance state.

After recording the verdict, do not switch role in-place. Call `attempt_completion` with task ID, verdict, resulting controller status, report path, and concise unresolved risks. The Orchestrator reloads MCP context and starts the next specialist as a fresh child.
