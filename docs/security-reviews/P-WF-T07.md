# Security review: P-WF-T07

- **Task:** P-WF-T07 — Create standalone n8n roadmap and task registry
- **Reviewer:** `platforminit-owasp-reviewer`
- **Stage:** security-review
- **Branch:** `chore/p-wf-t07-workflow`
- **Verdict:** CLEAR

## Scope and evidence

Reviewed the two declared non-state implementation files:

- [`n8n/tasks/README.md`](../../n8n/tasks/README.md)
- [`docs/n8n/N8N_ROADMAP.md`](../../docs/n8n/N8N_ROADMAP.md)

Directly required trust-boundary evidence:

- [`n8n/tasks/tracker.json`](../../n8n/tasks/tracker.json)
- [`tools/task_controller/taskctl.py`](../../tools/task_controller/taskctl.py)
- [`tools/task_controller/test_taskctl.py`](../../tools/task_controller/test_taskctl.py)
- Existing correctness review [`docs/reviews/P-WF-T07.md`](../reviews/P-WF-T07.md)
- Controller-verified `git diff --check` result: `GIT_DIFF_CHECK_OK`

Controller-owned changes under [`tasks/tracker.json`](../../tasks/tracker.json) and [`tasks/active/`](../../tasks/active/) were treated as generated/task state and not as product changes. The working-tree review also showed no additional non-state implementation path beyond [`docs/n8n/N8N_ROADMAP.md`](../../docs/n8n/N8N_ROADMAP.md) and the new registry README.

## Findings

No security, privacy, secret-exposure, or release-blocking findings.

### Secret and privacy review — PASS

The reviewed roadmap, registry README, and referenced n8n registry contain no credentials, tokens, private keys, customer data, private endpoints, IP addresses, or internal hostnames. The runtime direction contains only architecture-level identifiers and generic paths such as `/srv/n8n`; it does not disclose a deployment endpoint or secret value. The references to secrets, OAuth, webhooks, PostgreSQL, Caddy, and Authentik are scope labels and design topics, not credentials or connection details.

### PlatformInit controller boundary — PASS

The separation contract is explicit and does not add a routing or mutation path into PlatformInit. The n8n registry omits PlatformInit controller fields and says it is not read, selected, summarised, or mutated by the PlatformInit controller. It also requires n8n dependencies to remain local registry IDs and treats CH01/CH02 as external prerequisites only.

The directly required controller check is intact: [`get_task()`](../../tools/task_controller/taskctl.py:99) rejects a task whose track is not `platform`, tracker validation requires exactly one `platform` track, and the CLI rejects `--track n8n` at argument parsing with exit code 2 (`invalid choice: 'n8n'`). The existing controller test [`test_non_platform_track_is_rejected()`](../../tools/task_controller/test_taskctl.py:148) provides regression evidence for this boundary. No changed file weakens these controls or creates a way to start or close n8n work through PlatformInit `taskctl`.

### Release safety and generated views — PASS

The change is documentation/registry-contract content only. No workflow, shell, infrastructure, secret, or release automation file was changed. The only other dirty paths are controller-owned task state and generated active views, as identified in the handoff. No generated-view drift or special release handling was introduced; the existing controller-written state must continue to be released through the normal controller/release-manager lifecycle.

## Acceptance-gap adjudication

1. **n8n roadmap outside PlatformInit roadmap:** Pass. [`docs/n8n/N8N_ROADMAP.md`](../../docs/n8n/N8N_ROADMAP.md) is the canonical n8n roadmap and explicitly excludes it from the PlatformInit canonical queue.
2. **Separate n8n registry:** Pass. [`n8n/tasks/tracker.json`](../../n8n/tasks/tracker.json) is separate from [`tasks/tracker.json`](../../tasks/tracker.json), with ownership and schema boundaries documented in [`n8n/tasks/README.md`](../../n8n/tasks/README.md).
3. **PlatformInit cannot start n8n tasks:** Pass. The controller remains platform-only, the CLI rejects the n8n track, and the n8n registry is not wired into PlatformInit selection or mutation.

## Unresolved-risk adjudication

- Reliance on the existing controller track restriction is acceptable for this docs/registry contract change. The restriction is enforced in controller code and covered by a focused regression test. The absence of a new CI assertion in the out-of-scope workflow is a follow-up hardening opportunity, not a security defect in this delta.
- The roadmap and registry pre-existing on `dev` does not create a release concern. This task adds traceability and ownership documentation without introducing secrets, runtime behavior, or a second PlatformInit controller source of truth.

## Verdict

**CLEAR.** No security or privacy issue requires rework. Record the verdict through the controller using the required `taskctl security` transition.
