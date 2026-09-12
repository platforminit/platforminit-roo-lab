# P-WF-T03 Review — Shrink MCP delivery context budget

## Review scope

- Branch: `chore/p-wf-t03-workflow`
- Commit under review: `3ce3520` versus `dev` (`0cb330a`)
- Product changed scope: exactly the four declared non-state files:
  [`context.py`](../../tools/platforminit_mcp/context.py), [`server.py`](../../tools/platforminit_mcp/server.py), [`validate_mode_access.py`](../../tools/platforminit_mcp/validate_mode_access.py), and [`PLATFORM_WORKFLOW_REFACTOR.md`](../roo-lab/PLATFORM_WORKFLOW_REFACTOR.md).
- Controller-owned working-tree changes under `tasks/active/` and `tasks/tracker.json` were ignored.
- No product code, tests, tracker state, or generated task views were modified by this review.

## Acceptance criteria

### 1. PlatformInit MCP is platform-only — PASS

[`_platform_tasks()`](../../tools/platforminit_mcp/context.py:86) selects only tasks whose `track` is `platform`; task summaries and delivery context explicitly emit `track: platform`. [`changed_scope()`](../../tools/platforminit_mcp/context.py:106) excludes the separate `n8n/` and `docs/n8n/` path prefixes and marks the result `platformOnly: true`. The server exposes only PlatformInit task/scope tools and the validator checks both static and runtime platform-only markers.

### 2. Changed-scope default and hard cap are bounded for small tasks — PASS

[`SCOPE_DEFAULT_FILES`](../../tools/platforminit_mcp/context.py:52) is 5 and [`SCOPE_HARD_CAP_FILES`](../../tools/platforminit_mcp/context.py:53) is 8. [`clamp_max_files()`](../../tools/platforminit_mcp/context.py:69) applies the default for invalid/missing values and clamps oversized values to 8. Both relevant tool schemas advertise minimum 1, maximum 8, and default 5 in [`server.py`](../../tools/platforminit_mcp/server.py:24). The validator statically checks these contracts and runtime smoke passes an oversized request.

### 3. Delivery context returns only stage-critical fields — PASS

[`delivery_context()`](../../tools/platforminit_mcp/context.py:203) returns exactly the compact top-level contract: context version, project/track, task, scope, handoff payload, and authoritative source. The former prose handoff rule, indexing block, and duplicated suggested paths are removed. Runtime validation compares top-level, task-summary, and scope key sets and rejects indexing hints in [`runtime_errors()`](../../tools/platforminit_mcp/validate_mode_access.py:311).

## Evidence commands and results

1. `pwd; grep -Eiq "microsoft|wsl" /proc/version && echo WSL_OK; id -un; git branch --show-current; git status --short; git remote -v` — PASS: WSL, user `hattila`, branch `chore/p-wf-t03-workflow`; only controller-owned task-state files were dirty; origin was present.
2. `git rev-parse --short HEAD; git rev-parse --short dev` — PASS: `3ce3520` and `0cb330a`.
3. `git diff --name-status dev...HEAD -- <four declared paths>` — PASS: exactly the four declared product paths.
4. `git diff --check dev...HEAD` — PASS, exit 0.
5. `python3 tools/platforminit_mcp/validate_mode_access.py` — PASS: 8 PlatformInit modes declare MCP access and required tools are enabled.
6. `python3 tools/platforminit_mcp/validate_mode_access.py --runtime` — PASS: runtime MCP smoke returned the authoritative PlatformInit task and passed delivery-context, platform-only, and hard-cap assertions.
7. Initial controller MCP calls — [`health`](../../tools/platforminit_mcp/server.py:103) reported `contextVersion: 2`; compact `get_delivery_context` returned the active `needs_review` task and scope, also with `contextVersion: 2`. This is stale relative to the changed contract's version 3, while the validator's spawned runtime server passed the version-3 checks.

## Unresolved risks and adjudication

1. **Hosted/editor MCP restart — operator step, not a patch defect:** the already-hosted MCP process is stale and must be restarted/reloaded before relying on the new context contract. A fresh child should call MCP health and reload `get_delivery_context`; stale cached context must not be carried across the stage boundary. The runtime validator proves the shipped stdio server is correct, but does not restart the editor-hosted process.
2. **`mcp-smoke.md` documentation drift — low-risk documentation gap:** it was intentionally outside the four-file product scope and the static validator still confirms command/mode/tool wiring. However, the command documentation now under-describes the new delivery-contract checks (platform-only, bounded default/hard cap, exact compact fields). This does not break the command, but should be updated in a follow-up documentation task rather than expanding this micro-task after the fact.
3. **`foreignPathsExcluded` count — accepted limitation:** the count is sufficient to prove foreign paths were observed and removed, while the returned `files` list remains platform-only. It does not expose which foreign paths were dropped, so it can hide cross-track coupling details from an operator. This is an observability limitation, not evidence that foreign files leak or that this task's platform-only contract fails; detailed path inspection should remain a separate diagnostic/reporting concern.
4. **Four-file task-size warning — justified:** the fourth file is the workflow contract documentation corresponding directly to the three-file MCP implementation/validator subsystem. The files form one coherent delivery-context contract, and the diff is bounded; no split is required.
5. **Additional finding:** none. Existing consumers of `get_delivery_context` should not depend on removed `handoff.rule`/`indexing` fields because the validator enforces the new contract and the documented handoff payload retains the routing-critical information (`stage`, `nextMode`/transition command via task summary). The validator is repeatable and makes no repository mutations.

## Verdict rationale

**APPROVE.** The patch is branch-correct, within the declared allowed scope, platform-only, bounded at both schema and runtime layers, and its compact payload is explicitly contract-tested. Focused validation passes. The stale editor-hosted process requires an operational restart/reload, and `mcp-smoke.md` has a follow-up documentation gap, but neither warrants blocking this scoped implementation.
