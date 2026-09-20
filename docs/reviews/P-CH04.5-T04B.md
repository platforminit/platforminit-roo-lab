# Review: P-CH04.5-T04B — Make CH05 consume the canonical operations identity

## Verdict

**APPROVE** — changed-files review found no correctness, integration, regression, idempotence, or acceptance-criteria blocker.

## Scope and lifecycle

- Task: `P-CH04.5-T04B`
- Branch: `batch/platform-ch05-identity-consumer`
- Controller entry status: `needs_review`
- Reviewed product paths: `platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh`, `platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh`, and `platform/observability/checkmk/README.md`.
- The three requested product paths are the only changed files in the bounded scope. The working tree also contains controller-generated task-view/tracker changes; those were not reviewed or modified.
- No product files, tests, generated views, or tracker state were modified by this review.

## Acceptance criteria

### 1. Canonical operations group is consumed, not parallel-owned — PASS

Evidence:

- [`ch05-3-enable-checkmk-trusted-header-sso.sh`](../../platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh:16) identifies CH04.5 as the group owner and sets the canonical name/slug.
- [`require_group()`](../../platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh:114) performs lookup, rejects a missing group, and rejects a name/slug mismatch. It contains no group create/update operation.
- [`ensure_user_in_group()`](../../platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh:144) only updates user membership; it does not create or patch the group definition.
- [`README.md`](../../platform/observability/checkmk/README.md:52) documents CH04.5 ownership, lookup-only consumption, fail-fast ordering, and membership-only convergence.

The implementation's Authentik `POST`/`PATCH` operations are for the proxy provider, application, outpost, and user membership, not the group endpoint. This preserves the CH04.5 ownership boundary while retaining idempotent membership convergence.

### 2. No active CH05 SSO path creates retired Zabbix/OpenObserve groups or depends on retired identities — PASS

Evidence:

- [`RETIRED_OPERATIONS_GROUPS`](../../platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh:23) is explicit, and [`require_group()`](../../platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh:118) hard-fails if the requested name or slug is retired.
- The static validator rejects group creation/patch patterns and requires the retired-identity guard in [`static_validate()`](../../platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh:78).
- The validator's location-scoped retired-name check is implemented at [`stale`](../../platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh:90), and the identity model check rejects retired desired-state entries at [`expect(not present, ...)`](../../platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh:66).
- [`README.md`](../../platform/observability/checkmk/README.md:63) states that CH05.3 creates/consumes neither retired group.

Negative control evidence passed: `/tmp/platforminit-evidence/neg-a.log` fails on a competing group writer, and `/tmp/platforminit-evidence/neg-b.log` fails when `Zabbix Admins` is inserted into the identity model.

### 3. Focused validation proves Authentik -> Traefik -> auth-shim without runtime mutation — PASS

Evidence:

- Runtime remains the default in [`VALIDATE_MODE`](../../platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh:15-16); static mode is opt-in at [`if [[ "$VALIDATE_MODE" == "static" ]]`](../../platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh:123).
- Static mode first requires all contract files and fails closed on missing paths at [`Static contract file is missing`](../../platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh:27-31). A reviewer rerun with `CH05_SSO_REPO_ROOT=/tmp/platforminit-review-missing-root` exited 1.
- The static checks cover the Authentik/Traefik boundary at [`static_validate()`](../../platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh:98-112) and the auth-shim bridge at [`proxy_set_header X-Remote-User`](../../platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh:113-120).
- The static branch exits before runtime `kubectl` checks at [`exit 0`](../../platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh:123-127), so it performs no cluster mutation.
- The claimed static evidence `/tmp/platforminit-evidence/P-CH04.5-T04B-static-sso-validate.log` contains all seven PASS lines and exit 0. A focused rerun produced the same result.

## Focused validation and review checks

- `git diff --check`: PASS, exit 0.
- Static validator rerun: PASS, exit 0.
- Missing-root static validation: FAILS CLOSED, exit 1.
- Negative control A: PASS as a negative test; competing group writer is rejected.
- Negative control B: PASS as a negative test; retired identity in the model is rejected.
- No infrastructure workflow, Authentik runtime, Kubernetes, DNS, Cloudflare, GitHub secret, or environment mutation was performed.
- No secret value was recorded in this report.

## Operator UX, idempotence, and documentation

The missing-canonical-group failure is consistent with the documented CH05.3 ordering: [`README.md`](../../platform/observability/checkmk/README.md:63-73) directs the operator to run `04.5 - Deploy Identity Foundation` first. Repeated successful runs can update only missing user membership and reconcile the separate provider/application/outpost contracts; group ownership remains untouched. The documented static/runtime behavior matches the implementation at [`README.md`](../../platform/observability/checkmk/README.md:84-98).

## Unresolved risks (accepted, not blockers)

- CH04.5 remains `upsert-no-prune`; a stale look-alike group slug can cause CH05.3 to hard-fail until CH04.5 is reconciled.
- Retired-stack references outside the three allowed paths remain outside this task's review scope.
- The static retired-name guard is intentionally heuristic and location-scoped; it is a focused contract check, not a repository-wide proof.
- Runtime validation was not run because it would require cluster access and the task forbids infrastructure mutation/workflows; unchanged runtime evidence should be reused by the orchestrator where available.

## Controller transition

The reviewer records exactly one verdict with:

```text
python3 tools/task_controller/taskctl.py review P-CH04.5-T04B --actor platforminit-openai-reviewer --verdict approve --report docs/reviews/P-CH04.5-T04B.md
```
