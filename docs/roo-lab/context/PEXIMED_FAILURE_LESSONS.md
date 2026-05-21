# Peximed Failure Lessons Applied to PlatformInit Roo Lab

## Why this exists

The Peximed project showed that agentic workflows fail when the repository does not enforce source of truth, branch discipline, validation state, and role boundaries.

PlatformInit Roo Lab must encode these lessons before full-access dev automation is allowed.

## Failure patterns to avoid

| Failure pattern | PlatformInit prevention |
|---|---|
| Agent follows outdated prompt instead of current repo reality | `NEXT_TASK.md` must be self-contained and current. |
| Wrong stack assumption | Architect mode must verify repo technology before task execution. |
| Task branch confusion | Orchestrator must check branch before delegation. |
| Task-by-task PR churn | Use batch branch lifecycle. |
| Reviewer runs too early | Review only after coder batch is complete. |
| OWASP tries to implement | OWASP mode is read-only. |
| Stale validation terminal blocks progress | Validation state must be explicit; if unavailable, stop and report exact blocker. |
| Context bloat | Keep roadmap, current state, and active task separated. |
| Frontend/product direction drift | Any product/architecture pivot requires Architect decision. |
| Windows shell leakage | WSL-only guard and rules. |

## Operational rule

Do not allow a generic “do everything” agent prompt. Every task must answer:

```text
Which branch?
Which mode?
Which files?
Which validation?
Which recovery path?
Which reviewer?
Which stop condition?
```

## Roo prompt rule

The human prompt should normally be short:

```text
Read tasks/active/NEXT_TASK.md and execute the active batch exactly as described.
```

The repo must carry the detailed contract.
