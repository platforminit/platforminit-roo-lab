# Lifecycle Routing Rule

This rule lives in `.roo/rules/`, so every PlatformInit mode loads it directly and not only through the
mode registry in [`.roomodes`](../../.roomodes).

## Terminal specialist stages

Every specialist lifecycle child is terminal at its own controller transition:

| Mode | Own stage | Own transition |
|---|---|---|
| `platforminit-deepseek-coder` | implementation | `taskctl submit <TASK-ID> --actor platforminit-deepseek-coder` |
| `platforminit-openai-reviewer` | review | its own reviewer verdict record through `taskctl` |
| `platforminit-owasp-reviewer` | security-review | its own `CLEAR`/`REVIEW_REQUIRED`/`BLOCK` record through `taskctl` |
| `platforminit-release-manager` | release | its own `taskctl complete` |

Each of those modes must:

1. run exactly this one stage;
2. record its own controller transition through `taskctl`;
3. finish with `attempt_completion`;
4. TERMINATE.

A specialist child is terminal and routes nothing onward: it must never hand off to the next lifecycle
stage, never call `new_task`, and never spawn a child. A specialist child must also never use
`switch_mode` to continue the lifecycle and never starts review, security-review, or release from the
implementation or review conversation.

## Orchestrator-only routing

The orchestrator is the only next-stage routing owner. It reloads MCP `get_delivery_context` after every
child returns and starts the next stage as one fresh `new_task` child in the controller-returned
`nextMode`, passing only the bounded handoff payload.

## Static proof boundary

`tools/platforminit_mcp/validate_pipeline_smoke.py` proves the contract text only: it can confirm that
this rule, `.roomodes`, and the smoke procedure state the terminal-stage and orchestrator-only-routing
invariants. It does not prove Zoo parent/child provenance and cannot observe a real runtime launch, so
the manual/runtime layer of [`.roo/commands/pipeline-smoke.md`](../commands/pipeline-smoke.md) FAILS when
a specialist child that itself launches the next lifecycle stage, including a nested `new_task` from a
specialist child.
