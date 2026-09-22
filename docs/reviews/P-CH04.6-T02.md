# Review — P-CH04.6-T02

## Verdict

**APPROVE** — the bounded implementation satisfies the three acceptance criteria based on the changed-files review and supplied focused evidence. No correctness, integration, scope, idempotence, or operator-UX defect was found that requires rework before security review.

## Scope and lifecycle

- Task: `P-CH04.6-T02` — Preserve identity ownership during Argo CD SSO reconciliation.
- Reviewed branch: `batch/platform-ch04-6-preserve-identity-ownership`.
- Compared the three allowed product paths against `dev`; the implementation is uncommitted as expected.
- The working tree also contains controller-managed state changes only. No additional product paths were introduced.
- WSL/environment and branch checks passed; `git diff --check` passed.
- The controller remains at `needs_review` until this verdict is recorded through `taskctl`.

## Acceptance criteria

### 1. CH04.6 group reconciliation preserves CH04.5 managed ownership attributes — MET

[`require_authentik_admin_group()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:632) consumes the group by exact-name lookup, rejects superuser/parent groups, requires all five ownership stamps, checks the CH04.5 reconciler identity and allowed consumer chapter, and returns a complete pre-run attribute snapshot. [`assert_group_ownership_preserved()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:717) re-reads the complete attribute bag after membership convergence and fails on any changed, cleared, added, or removed attribute. The reconciler contains no group create/update/delete operation; membership is the only group-adjacent write.

The supplied static validator and ownership harness pass, including the pre-T02 prefix anti-vacuity run failing the ownership controls. The live validator was not able to execute in this workspace because `kubectl`/the Authentik rollout is unavailable; the implementation reports that limitation honestly rather than treating static evidence as live proof.

### 2. Argo CD group-to-role mapping remains deterministic and does not broaden privilege — MET

[`validate_argocd_admin_group_binding()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:271) gates the input before the first write using the CH04.5 taxonomy, non-superuser and consumer-chapter checks, and a strict RBAC-safe group-name grammar. [`verify_argocd_rbac_mapping()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1113) reads back the applied object and requires exactly one expected admin binding, `policy.default: role:readonly`, and a `groups` scope. The static render check proves two renders are byte-identical and contain exactly one expected group binding. The validator's fixture suite exercises accepted and rejected groups twice with identical decisions, including injection, foreign-owner, superuser, undeclared, and foreign-consumer cases.

The live mapping read-back remains unexecuted offline, and this is correctly recorded as residual risk rather than a failed or fabricated pass.

### 3. Focused validation covers repeat reconciliation and ownership preservation — MET

The new `--static` dispatch occurs before the first `kubectl` call ([`run_static_validation()`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:112), dispatch at line 450). The supplied static evidence reports 31 controls with zero failures, including syntax, no group writes, ownership snapshot/re-read tokens, deterministic RBAC rendering, repeat fixture decisions, and no-live-access ordering. The supplied ownership harness and CH04.5 model/cross-consumer evidence also pass. The focused live validator remains read-only and fails closed on missing ownership or broadened RBAC state.

## Integration and UX review

- The workflow continues to pass `ARGOCD_ADMIN_GROUP` and the selected username into both reconciler and validator; default inputs remain compatible.
- The new pre-write failure messages direct operators to rerun CH04.5, preserving the ownership boundary rather than silently repairing consumer-owned state.
- Drifted deployments now stop on unstamped/foreign groups or non-contracted RBAC state. This is an intentional, documented behavior change and is appropriate for the security-sensitive admin binding.
- Repeat reconciliation retains the existing config convergence/restart short-circuit and membership short-circuit. The provider/application PATCH behavior remains the pre-existing T01 behavior and is documented as such.
- No secret values appear in this report or the reviewed additions. The existing `kubectl -p` exposure, prose-dependent redaction, legacy-key policy, and README/advisory documentation drift remain pre-existing residual risks and are outside this task's allowed scope.

## Evidence reused

- `/tmp/platforminit-evidence/P-CH04.6-T02-static-validator.log`: 31 controls, zero failures.
- `/tmp/platforminit-evidence/P-CH04.6-T02-static-prefix.log`: anti-vacuity failures against the pre-T02 reconciler.
- `/tmp/platforminit-evidence/P-CH04.6-T02-ownership-harness.log` and prefix log: ownership preservation harness and anti-vacuity result.
- `/tmp/platforminit-evidence/P-CH04.6-T02-ch04-5-model-contract.log`: CH04.5 contract PASS.
- `/tmp/platforminit-evidence/P-CH04.6-T02-ch04-5-cross-consumer.log`: CH04.5/CH04.6/CH05 cross-consumer PASS.
- `/tmp/platforminit-evidence/P-CH04.6-T02-live-validator.log`: live validation unavailable at Authentik rollout prerequisite; no live acceptance pass claimed.
- Required `git diff --check`: PASS.

## Consolidated findings

No review-blocking findings.

## Residual risk

The deployed Authentik group attribute preservation and Argo CD RBAC read-back branches still require an approved live CH04.6 execution on a healthy development host. Until that evidence exists, acceptance criteria 1 and 2 are repository/static-proven rather than live-runtime-proven. The documented pre-existing secret-argument exposure and legacy-key warning policy remain for their existing follow-up work.
