# Historical: PlatformInit Agent Operating Layer v2

This document records the pre-controller / pre-fresh-child agent-layer design. It is retained as
historical design context only and is **not an active Zoo Code execution contract**.

## Current authoritative workflow

Use these sources for current behavior:

1. [`.roomodes`](../../.roomodes) — project Zoo Code modes and mode-local instructions;
2. [`.roo/rules.md`](../../.roo/rules.md) — global task, safety, lifecycle, context, and approval rules;
3. [`.roo/rules/05-lifecycle-routing.md`](../../.roo/rules/05-lifecycle-routing.md) — terminal specialist stages and Orchestrator-only routing;
4. [`PLATFORM_WORKFLOW_REFACTOR.md`](PLATFORM_WORKFLOW_REFACTOR.md) — compact MCP/fresh-child workflow contract;
5. [`TASK_ORCHESTRATION_MODEL.md`](TASK_ORCHESTRATION_MODEL.md) — controller-owned task lifecycle.

## What remains useful from v2

The v2 design established several ideas that remain valid:

- a dedicated multi-role PlatformInit agent team instead of one generic coding assistant;
- explicit architecture, implementation, correctness review, security review, diagnostics, release, and documentation responsibilities;
- WSL-only execution and strict branch discipline for this repository;
- current repository state outranking archived memory or historical component choices;
- Peximed failure lessons as negative design input.

## Superseded behavior

Do not reuse these v2-era behaviors as current instructions:

- Roo Code branding as the active tool; Zoo Code is the current execution environment;
- batch-based review/release gates across multiple task rows;
- conversation-preserving lifecycle continuation;
- the old first-validation branch `batch/roo-lab-first-validation`;
- any first-run sequence that bypasses `taskctl`, MCP compact context, or the fresh-child lifecycle.

Current delivery is one tracked task at a time:

```text
Orchestrator
  -> fresh implementation child
  -> fresh correctness-review child
  -> fresh security-review child
  -> fresh Release Manager child
  -> human PR merge
```

Each specialist owns only its own controller transition and terminates through `attempt_completion`.
