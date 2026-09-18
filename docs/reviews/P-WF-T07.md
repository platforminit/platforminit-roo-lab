# P-WF-T07 independent review

- **Task:** P-WF-T07 — Create standalone n8n roadmap and task registry
- **Branch:** `chore/p-wf-t07-workflow`
- **Review verdict:** APPROVE
- **Review scope:** the two non-state changed files, directly affected controller behavior, and focused evidence only

## Findings

No correctness, integration, regression, idempotence, workflow UX, or acceptance-criteria defects were found.

The implementation does not recreate the roadmap or registry because both canonical artifacts already exist on `dev`. The added contract and traceability layer is a legitimate closure of this task: it documents the canonical locations, schema/ownership boundary, parked semantics, chapter coverage, verification recipe, and the explicit prohibition on PlatformInit selection or mutation. Recreating existing artifacts would risk duplicate sources of truth and is not required by the acceptance criteria.

## Acceptance criteria

1. **n8n roadmap outside the PlatformInit roadmap — PASS.** The canonical roadmap is [`docs/n8n/N8N_ROADMAP.md`](../n8n/N8N_ROADMAP.md), while [`docs/roo-lab/N8N_ROADMAP.md`](../roo-lab/N8N_ROADMAP.md) is a relocation pointer rather than a competing roadmap. The changed roadmap identifies the canonical registry and explicitly excludes PlatformInit queues and views.
2. **Separate n8n registry — PASS.** [`n8n/tasks/tracker.json`](../../n8n/tasks/tracker.json) is a separate parked registry. [`n8n/tasks/README.md`](../../n8n/tasks/README.md) defines its schema and expressly omits PlatformInit controller fields. Focused consistency evidence reports 13 unique tasks/orders with resolved dependencies; `tasks/tracker.json` contains zero `N8N-` entries.
3. **PlatformInit cannot start n8n tasks — PASS.** Focused execution of `taskctl next --track n8n` exits 2 with an invalid-track error, while `taskctl next --track platform` continues to select P-WF-T07. The controller implementation restricts the track choice to `platform`, rejects non-platform task records, and does not load the n8n registry.

## Scope and lifecycle review

- The product delta is within the declared allowed paths: [`n8n/tasks/README.md`](../../n8n/tasks/README.md) and [`docs/n8n/N8N_ROADMAP.md`](../n8n/N8N_ROADMAP.md). Controller-owned changes under [`tasks/tracker.json`](../../tasks/tracker.json) and [`tasks/active/`](../../tasks/active/) were not edited by this reviewer.
- The branch is `chore/p-wf-t07-workflow`; the task remains `needs_review` before this verdict.
- `git diff --check` passed.
- No secrets, runtime changes, destructive operations, infrastructure workflows, or GitHub environment mutations were introduced.
- The parked registry is intentionally not wired into PlatformInit validators or task selection. This preserves separate ownership and avoids a competing PlatformInit source of truth.
- The absence of a new CI assertion for n8n separation is not a defect in this bounded task: the controller's existing track restriction is the enforced runtime boundary, and the focused command evidence demonstrates it. Adding CI coverage would be outside the allowed product scope.

## Unresolved risks

The separation contract is primarily documentation plus the existing controller restriction; future changes to controller code could weaken that boundary. The report and registry verification recipe make the contract observable, but a dedicated CI assertion remains a reasonable follow-up outside this task. This does not block approval because the current controller behavior is enforced and verified.

## Focused evidence

- WSL/environment and branch checks passed.
- [`git diff --check`](../../.gitignore) passed; no whitespace errors were reported. (The command has no source-file link.)
- n8n registry self-check: 13 tasks, unique IDs/orders, dependencies resolved, roadmap pointer resolved.
- PlatformInit tracker n8n count: `0`.
- PlatformInit controller n8n-track attempt: exit `2`, invalid choice; platform next-task selection remained P-WF-T07.
