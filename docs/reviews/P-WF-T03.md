# P-WF-T03 Review — Shrink MCP delivery context budget

## Re-review scope and history

- Branch: `chore/p-wf-t03-workflow`; HEAD: `e4715b8` (`fix(mcp): bound and validate every caller-supplied MCP tool input`).
- Rework reviewed: `git diff 0535a6a...e4715b8`; whole task scope: `git diff dev...HEAD`.
- Product scope remains the four declared non-state files: [`context.py`](../../tools/platforminit_mcp/context.py), [`server.py`](../../tools/platforminit_mcp/server.py), [`validate_mode_access.py`](../../tools/platforminit_mcp/validate_mode_access.py), and [`PLATFORM_WORKFLOW_REFACTOR.md`](../roo-lab/PLATFORM_WORKFLOW_REFACTOR.md).
- Review #1 approved implementation commit `3ce3520`.
- Security #1 (`0535a6a`) raised M-01 because caller-supplied `base` reached the Git argv without a bounded/allowlisted contract.
- This re-review adjudicates the rework commit `e4715b8`; controller-owned changes under [`tasks/active/`](../../tasks/active/) and [`tasks/tracker.json`](../../tasks/tracker.json) were ignored and not committed.

## Verdict

**APPROVE.** The rework closes M-01 without identifying a legitimate in-repository caller that would break. Validation occurs before Git subprocess construction, the schema derives the handler argument allowlist, and the compact context contract remains version 3 and stage-critical only.

## Acceptance criteria

### 1. PlatformInit MCP is platform-only — PASS

[`_platform_tasks()`](../../tools/platforminit_mcp/context.py:147) selects only `track == platform`; task summaries and delivery context emit the platform track. [`changed_scope()`](../../tools/platforminit_mcp/context.py:168) excludes `n8n/` and `docs/n8n/` paths and marks the result `platformOnly: true`. Static and runtime validation cover these markers and the required MCP tool surface.

### 2. Changed-scope default and hard cap are bounded for small tasks — PASS

[`SCOPE_DEFAULT_FILES`](../../tools/platforminit_mcp/context.py:53) is 5 and [`SCOPE_HARD_CAP_FILES`](../../tools/platforminit_mcp/context.py:54) is 8. [`validate_max_files()`](../../tools/platforminit_mcp/context.py:128) rejects booleans, floats, numeric strings, lists, and other non-integers, while integer values are clamped to 1..8. Both scope-bearing schemas advertise integer type, minimum 1, maximum 8, and default 5. The runtime oversized request remains clamped to the hard cap.

### 3. Delivery context returns only stage-critical fields — PASS

[`delivery_context()`](../../tools/platforminit_mcp/context.py:266) still returns `contextVersion: 3` and exactly the compact top-level contract: project/track, task, bounded scope, handoff payload, and authoritative source. No rework change restores the removed prose handoff rule, indexing block, or duplicated suggested paths. Static and runtime validators compare the exact field sets.

## Tightened input contract and integration review

### `base` callers

Path-scoped searches across [`.roo/`](../../.roo/), [`.github/workflows/`](../../.github/workflows/), [`tools/`](../../tools/), [`scripts/`](../../scripts/), and the relevant workflow documentation found no external caller that supplies a `base` value to the MCP tools. The only operational defaults are the server/schema default `dev` and the controller/MCP delivery request used in this review, which is `dev`; both remain allowlisted. `origin/feature-*` appears only as an intentionally rejected validator case and as a documented unresolved compatibility/design risk, not as an active caller. Rejecting such refs is acceptable for this micro-task because the new contract explicitly supports only `dev`, `main`, `origin/dev`, and `origin/main`.

### `maxFiles` callers

No repository caller or command example supplies a string or float `maxFiles`. The shipped schemas use integer values, and the validator intentionally tests rejection of `"5"`, `2.5`, `True`, and list input. This is an intentional contract tightening, not a regression for the discovered consumers. Oversized integers retain the prior bounded/clamping behavior.

### `taskId` compatibility

[`TASK_ID_PATTERN`](../../tools/platforminit_mcp/context.py:66) permits letters, digits, dots, underscores, and hyphens after a non-empty alphanumeric first character, with a 64-character cap. Legitimate identifiers including `P-WF-T03` and dotted n8n/platform-style identifiers such as `P-CH04.5-T02` are accepted. Shell metacharacters, path separators, whitespace, and oversized identifiers are rejected before tracker lookup.

### Error semantics

The path-scoped search found no consumer assertion or documentation dependency on the removed exception text. The validator now asserts controlled `-32602` responses for unknown tools, unexpected argument names, non-object `params`/`arguments`, and [`InvalidToolInput`](../../tools/platforminit_mcp/context.py:90). Other handler exceptions return constant `-32603` text without exception details or host paths. JSON parse errors remain the standard `-32700`; a non-object JSON-RPC message remains the protocol-level `-32600` invalid-request response, which is distinct and appropriate.

### Stdio/editor-hosted path and drift prevention

[`handle()`](../../tools/platforminit_mcp/server.py:106) routes all tool inputs through validation-bearing context functions before [`changed_scope()`](../../tools/platforminit_mcp/context.py:168) constructs any Git command. [`allowed_arguments()`](../../tools/platforminit_mcp/server.py:98) derives accepted argument names from `TOOLS` schemas, preventing schema/handler argument-list drift. The runtime validator exercises invalid inputs, unknown tools, unexpected arguments, non-object arguments, malformed JSON, and the normal health/task/context calls.

## Focused evidence

1. `health` MCP call — PASS: `ok: true`, project `platforminit`, `contextVersion: 3`.
2. `get_delivery_context` MCP call — PASS: status `needs_review`, platform track, bounded scope budget `{target: 3, warning: 5, hardSplitAbove: 5, hardCap: 8}`, and compact context version 3.
3. Environment/branch check — PASS: WSL, user `hattila`, branch `chore/p-wf-t03-workflow`; only controller-owned task-state files were dirty before this report update.
4. `git diff 0535a6a...e4715b8` — PASS: rework limited to the four declared product paths.
5. `git diff --check` — PASS, exit 0.
6. `python3 tools/platforminit_mcp/validate_mode_access.py` — PASS: 8 PlatformInit modes declare MCP access and required tools are enabled.
7. `python3 tools/platforminit_mcp/validate_mode_access.py --runtime` — PASS: runtime MCP smoke returned the authoritative PlatformInit task and passed compact-contract, platform-only, hard-cap, input-rejection, and error-safety assertions.

## Unresolved risks

1. No outbound GitHub access is available from this workspace; remote fetch/push/PR evidence remains a known release-stage blocker.
2. [`.roo/commands/mcp-smoke.md`](../../.roo/commands/mcp-smoke.md) has documentation drift: it does not fully describe the newer compact-contract and input-rejection assertions. This is deferred rather than expanding this micro-task.
3. `origin/feature-*` refs are now rejected by design. No active caller was found, but any future caller must use the four documented allowlisted refs.
4. The editor-hosted MCP process must be restarted/reloaded at stage boundaries so it serves context version 3; the fresh health/context calls and spawned runtime validator show the shipped path is correct.

## Controller transition

After this report is committed, record exactly one verdict:

```text
python3 tools/task_controller/taskctl.py review P-WF-T03 --actor platforminit-openai-reviewer --verdict approve --report docs/reviews/P-WF-T03.md
```
