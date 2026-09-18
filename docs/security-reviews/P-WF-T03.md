# P-WF-T03 OWASP security/privacy/release re-review

## Verdict

**CLEAR** — M-01 is closed by the rework. No new security, privacy, or release-blocking finding was identified in the bounded `dev...HEAD` scope.

## Scope and evidence boundary

- Branch verified: `chore/p-wf-t03-workflow`.
- Rework focus: `git diff 0535a6a...e4715b8`.
- Current product scope: [`context.py`](../../tools/platforminit_mcp/context.py), [`server.py`](../../tools/platforminit_mcp/server.py), [`validate_mode_access.py`](../../tools/platforminit_mcp/validate_mode_access.py), and [`PLATFORM_WORKFLOW_REFACTOR.md`](../../docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md).
- Gate artifact [`P-WF-T03.md`](../../docs/reviews/P-WF-T03.md) was not modified.
- Controller-owned [`tasks/tracker.json`](../../tasks/tracker.json) and [`tasks/active/`](../../tasks/active/) changes were ignored and not staged.
- [`mcp.json`](../../.roo/mcp.json) is unchanged across `dev...HEAD`.

## Findings

### M-01 — Unbounded and insufficiently constrained `base` MCP input — CLOSED

The original review found that caller-supplied `base` reached the Git revision expression without bounds. The rework now applies [`validate_base()`](../../tools/platforminit_mcp/context.py:98) before construction of the Git command list, using `BASE_ALLOWED_REFS`, `BASE_MAX_LENGTH`, `BASE_REF_PATTERN`, explicit rejection of option-like input and `..`, and a conservative allowlist of `dev`, `main`, `origin/dev`, and `origin/main`.

Validation is present on every exported path that can reach Git or tracker state: [`delivery_context()`](../../tools/platforminit_mcp/context.py:266) delegates to [`active_task_summary()`](../../tools/platforminit_mcp/context.py:245) and [`changed_scope()`](../../tools/platforminit_mcp/context.py:168); [`changed_scope()`](../../tools/platforminit_mcp/context.py:169) validates `base` and `maxFiles` before any `subprocess.run`; [`active_task_summary()`](../../tools/platforminit_mcp/context.py:246) reaches [`select_task()`](../../tools/platforminit_mcp/context.py:155), which validates `taskId`; and the direct server routes use those same entry points. No raw caller-supplied revision remains.

[`subprocess.run()`](../../tools/platforminit_mcp/context.py:179) receives argv lists and does not use a shell. The server catches [`InvalidToolInput`](../../tools/platforminit_mcp/server.py:159) as controlled `-32602` errors; unexpected exceptions become the constant `-32603` message `internal tool error`, without exception text, traceback, Git stdout, or stderr.

**Closure evidence:** static validator assertions cover allowlisted round trips, invalid inputs, direct-entry-point bypasses, schema bounds, and controlled RPC errors. Direct stdio probes rejected oversized, option-like, `..`, unsupported, and non-string `base`; non-integer `maxFiles`; and malformed/non-string `taskId`. All returned `-32602`, with no hostile input, host path, secret path, or traceback echoed.

### No new findings

- No new credential, environment, logging, or secret-file read was introduced.
- Returned changed paths remain filtered from controller state, foreign-track paths, and secret-bearing path classes (`*.pem`, `*.key`, `*.p12`, `*.pfx`, `.local_secrets/`).
- `.roo/mcp.json` has no permission, `alwaysAllow`, or cross-project server change.
- The validator checks are deterministic and non-vacuous; the static layer includes direct invalid-entry-point assertions and runtime controlled-error assertions. Repeated focused validator execution was stable.

## Acceptance adjudication

1. **PlatformInit-only:** Pass. Platform task selection is restricted to `track == platform`, and changed scope excludes the separate `n8n/` and `docs/n8n/` paths.
2. **Bounded changed scope:** Pass. The default is 5 files, the hard cap is 8, and `maxFiles` is integer-validated and clamped before Git execution.
3. **Stage-critical delivery context:** Pass. The delivery context exposes only the compact contract fields and the current stage-critical handoff payload.

## Focused validation

- `git diff --check dev...HEAD` — PASS, exit 0.
- `python3 tools/platforminit_mcp/validate_mode_access.py` — PASS: 8 PlatformInit modes.
- `python3 tools/platforminit_mcp/validate_mode_access.py --runtime` — PASS: runtime MCP smoke and authoritative task/compact contract checks.
- Direct hostile stdio probe — PASS: 9 hostile requests, all controlled `-32602`, no stderr, no traceback, no host/secret-path echo.
- Valid-input stdio probe — PASS: server returned successfully with no stderr.
- `.roo/mcp.json` diff check — PASS: unchanged across `dev...HEAD`.
- `git diff --check 0535a6a...e4715b8` — PASS by the reviewed rework diff.
- MCP `health` and `get_delivery_context` — PASS, `contextVersion: 3`, `needs_security_review`, platform-only compact context.

## Unresolved risks and deferred items

- No outbound GitHub access exists in this workspace; remote release evidence and push/PR operations remain blocked by the environment.
- [`mcp-smoke.md`](../../.roo/commands/mcp-smoke.md) documentation drift is deferred to the later workflow task and does not widen runtime permissions.
- `origin/feature-*` refs remain intentionally rejected by the allowlist.

## Controller transition

After this report is committed, execute exactly:

`python3 tools/task_controller/taskctl.py security P-WF-T03 --actor platforminit-owasp-reviewer --verdict clear --report docs/security-reviews/P-WF-T03.md`
