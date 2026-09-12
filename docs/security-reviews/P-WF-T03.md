# P-WF-T03 OWASP security/privacy/release review

## Verdict

**REVIEW_REQUIRED** — one medium-severity input-validation/release finding remains. The changed code is otherwise acceptable against the stated security and privacy criteria, but the MCP server does not bound or validate the caller-supplied `base` ref before embedding it into Git argument vectors. This is not shell injection, because `subprocess.run` receives an argv list, but option/ref injection and unbounded Git work remain possible for a locally hosted server.

## Scope and evidence boundary

- Branch verified: `chore/p-wf-t03-workflow`.
- Reviewed `dev...HEAD` with base `0cb330a`; implementation `3ce3520`; review artifact commit `079306e`.
- Product diff: [`context.py`](../../tools/platforminit_mcp/context.py), [`server.py`](../../tools/platforminit_mcp/server.py), [`validate_mode_access.py`](../../tools/platforminit_mcp/validate_mode_access.py), and [`PLATFORM_WORKFLOW_REFACTOR.md`](../../docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md). The informational [`docs/reviews/P-WF-T03.md`](../../docs/reviews/P-WF-T03.md) was not treated as product evidence.
- Dirty [`tasks/active/**`](../../tasks/active/) and [`tasks/tracker.json`](../../tasks/tracker.json) state was ignored and was not staged.
- [` .roo/mcp.json`](../../.roo/mcp.json) was checked by diff and was unchanged. (The leading space is intentionally absent from the actual link target.)

## Findings

### M-01 — Unbounded and insufficiently constrained `base` MCP input

**Severity:** Medium. **Status:** Review required.

[`get_delivery_context`](../../tools/platforminit_mcp/server.py:24) and [`get_changed_scope`](../../tools/platforminit_mcp/server.py:51) accept an arbitrary string `base`; unlike `maxFiles`, it has no length, character, or allowed-ref constraint. The server passes it to [`changed_scope`](../../tools/platforminit_mcp/context.py:106), which constructs `git diff --name-only f"{base}...HEAD"` and executes it in [`subprocess.run`](../../tools/platforminit_mcp/context.py:116). Because this is argv-based rather than shell-based, metacharacters do not provide direct command execution. Nevertheless, a caller can supply a very large or unusual Git revision expression, potentially causing excessive Git parsing/work, and a value beginning with option-like content should not be accepted as a trusted revision selector. The resulting `scope.base` also reflects attacker-controlled text.

**Required remediation before clear:** enforce a small maximum length and a conservative Git ref/revision grammar, reject invalid values (including option-like input), or replace caller-selected refs with an allowlisted set such as `dev` plus explicitly supported local refs. Add deterministic static/runtime coverage for invalid and oversized `base` values and ensure the error is a controlled JSON-RPC error rather than an emitted exception string.

### Informational — hosted MCP process is stale

The initial controller MCP calls reported `contextVersion: 2`, while the shipped implementation declares version 3 in [`CONTEXT_VERSION`](../../tools/platforminit_mcp/context.py:22) and the server health response reports 3 in [`handle`](../../tools/platforminit_mcp/server.py:103). This is an editor-hosted process restart/reload requirement, not evidence of a source-code defect. Consumers must not rely on the new contract until the process is restarted and a fresh child reloads context.

### Informational — smoke documentation drift

[`mcp-smoke.md`](../../.roo/commands/mcp-smoke.md) under-describes the two new validator checks. It is outside the allowed changed scope and is a follow-up/resynchronization candidate for P-WF-T08; it does not widen permissions or create a runtime exposure.

### Accepted low-risk limitations

- [`foreignPathsExcluded`](../../tools/platforminit_mcp/context.py:136) exposes only a count, not foreign path names. Returned file entries are filtered against [`FOREIGN_TRACK_PATHS`](../../tools/platforminit_mcp/context.py:46).
- Unknown task IDs return the bounded marker `unknown-platform-task` from [`active_task_summary`](../../tools/platforminit_mcp/context.py:182), with no tracker payload.
- Tracker metadata is serialized as JSON. New fields are not interpolated into shell commands; transition commands are strings returned to the consumer. The controller remains the authoritative executor. A future hardening pass should nevertheless validate tracker-controlled actor/ref fields at the controller boundary.
- Four non-state files rather than the target three is a task-size warning only; the files form one MCP subsystem plus its contract documentation.

## Acceptance adjudication

1. **PlatformInit-only:** Pass. [`_platform_tasks`](../../tools/platforminit_mcp/context.py:86) filters `track == platform`; changed scope excludes `n8n/` and `docs/n8n/`; payloads mark the track/platform-only state.
2. **Bounded changed scope:** Pass for `maxFiles`. [`clamp_max_files`](../../tools/platforminit_mcp/context.py:69) defaults invalid values and clamps to the hard cap; the server schema advertises minimum 1, maximum 8, and default 5, and the server calls the same clamp through [`changed_scope`](../../tools/platforminit_mcp/context.py:107). M-01 remains for the separate `base` input.
3. **Stage-critical delivery context:** Pass. [`delivery_context`](../../tools/platforminit_mcp/context.py:203) returns the reduced contract; runtime validation checks exact top-level/task/scope keys and rejects the removed indexing block in [`runtime_errors`](../../tools/platforminit_mcp/validate_mode_access.py:311).

## Security/privacy checks

- No credentials, tokens, environment values, or secret contents were read, logged, or emitted by the changed implementation.
- No changed payload path can be `*.pem`, `*.key`, `*.p12`, `*.pfx`, or under `.local_secrets/`; state and foreign-track prefixes are excluded before returned paths.
- `.roo/mcp.json` permissions and `alwaysAllow` scope were unchanged; no cross-project server was added.
- No shell interpolation was introduced. The identified `base` issue is argument/ref validation and resource-exhaustion hardening, not a demonstrated shell command injection.

## Focused validation

- `git diff --check dev...HEAD` — PASS, exit 0.
- `python3 tools/platforminit_mcp/validate_mode_access.py` — PASS: 8 PlatformInit modes.
- `python3 tools/platforminit_mcp/validate_mode_access.py --runtime` — PASS: runtime MCP smoke, authoritative task, compact contract, platform-only markers, and oversized `maxFiles` hard-cap assertion.
- Initial MCP `health` / `get_delivery_context` — PASS availability, but stale `contextVersion: 2` as recorded above.

## Controller transition

After this report is committed, the required transition is:

`python3 tools/task_controller/taskctl.py security P-WF-T03 --actor platforminit-owasp-reviewer --verdict review_required --report docs/security-reviews/P-WF-T03.md`
