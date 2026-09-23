# Review Flow Rules

Use one tracked PlatformInit task lifecycle at a time. The controller state, `.roo/rules.md`, and
`.roo/rules/05-lifecycle-routing.md` are authoritative; this rule must not introduce a competing
batch lifecycle.

## Canonical Zoo Code lifecycle

1. The Orchestrator completes the fresh-`dev` startup gate, resolves exactly one runnable task, creates
   or switches to that task branch, and records `taskctl start`.
2. A fresh implementation child changes only the bounded task scope, runs focused validation as needed,
   and records `taskctl submit`.
3. The Orchestrator reloads MCP `get_delivery_context`.
4. A fresh OpenAI Reviewer child reviews the current changed scope and records exactly one `taskctl review`
   verdict.
5. On approval, the Orchestrator reloads MCP and starts a fresh OWASP Reviewer child. Rework returns to a
   fresh implementation child; a blocker returns to the Orchestrator.
6. On security `clear`, the Orchestrator reloads MCP and starts a fresh Release Manager child. The Release
   Manager verifies evidence, records `taskctl complete`, commits closure/evidence state, pushes the task
   branch, and opens or updates the feature-to-`dev` PR.
7. Merge remains a human action.

## Rules

- Do not combine adjacent tracker rows into one implementation lifecycle merely because they share a
  chapter or subsystem.
- Every task that reaches review receives its own correctness review, security review, release gate, and PR.
- Specialist children are terminal at their own controller transition: they call `attempt_completion`
  and do not route, spawn, or hand off the next lifecycle stage.
- Reviewer and OWASP stages must not modify product/source files. Their writable output is lifecycle
  evidence such as `docs/reviews/<TASK-ID>.md` and `docs/security-reviews/<TASK-ID>.md`.
- Only the Release Manager closes `ready_to_close`, and only through `taskctl complete`.
- Never merge automatically.
- The normal human entrypoint is `/next-task`; generated `tasks/active/**` views remain read-only.
