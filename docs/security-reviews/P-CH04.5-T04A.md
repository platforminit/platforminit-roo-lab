# Security Review: P-CH04.5-T04A

- **Stage:** security-review
- **Reviewer:** `platforminit-owasp-reviewer`
- **Branch:** `batch/platform-ch04-5-checkmk-identity-alignment`
- **Verdict:** CLEAR

## Scope and evidence

Reviewed only the controller-confirmed five changed product files:

- `platform/identity/groups/platforminit-groups.yaml`
- `platform/identity/users/bootstrap-technical-users.yaml`
- `platform/identity/docs/ch04-5-identity-foundation.md`
- `platform/identity/docs/ch04-5-identity-model-contract.md`
- `platform/identity/validate/ch04-5-validate-identity-model-contract.sh`

Read-only checks actually run:

1. `git status --short`, `git branch --show-current`, `git diff --name-only dev...HEAD`, and `git diff --check dev...HEAD`.
2. Read-only inspection of all five changed files and their security-relevant diff/content.
3. Targeted grep over the changed scope for credential, secret, token, privilege, deletion/prune, Checkmk and retired-stack indicators.
4. `bash platform/identity/validate/ch04-5-validate-identity-model-contract.sh`.

The focused validator passed with `pass=40`, `warn=1`, `fail=0`. The warning is the pre-existing/follow-up CH04.6 empty-attributes advisory, not a failure introduced by this taxonomy change.

## Findings

### No blocking security finding

- The canonical `PlatformInit Operations` group is application-scoped, consumed by CH05, and explicitly has `is_superuser: false`.
- `Authentik Admins` remains the sole `is_superuser: true` group. No application group gains superuser status.
- Retired `Zabbix Admins` and `OpenObserve Admins` are absent from the active group model and bootstrap membership. The unsupported Operations Admins/Viewers and Checkmk role split are not formalized.
- Bootstrap membership contains only the documented break-glass username indirection and secret **name** `AUTHENTIK_BOOTSTRAP_PASSWORD`; no password, token, or credential value is present. Technical identities remain `create_by_default: false` with `none-provisioned` credential sources.
- The validator confirms the reconciler has no DELETE, prune, force, technical-user creation, or randomness path. Therefore removal from desired state does not imply a destructive live delete or silent grant.
- The change is contract/desired-state only and does not add infrastructure, Authentik, Kubernetes, DNS, Cloudflare, GitHub secret, or environment mutation.

## Residual risks accepted or escalated

1. **Escalated as follow-up, not a blocker:** CH05 still has a parallel `PlatformInit Operations` definition until `P-CH04.5-T04B`; this is a competing-writer/idempotence risk and must remain tracked.
2. **Accepted for this bounded change:** stale retired-stack references remain outside the allowed scope and require separate cleanup.
3. **Accepted by design:** the reconciler is upsert-no-prune, so already-present retired Authentik groups are not deleted automatically. This avoids destructive behavior but leaves possible stale access until an explicitly governed cleanup task.
4. **Known validator warning:** CH04.6 can clear CH04.5 ownership attributes with an empty attributes payload; CH04.5 re-stamps them on rerun. This remains a follow-up advisory and is outside this task's allowed files.

## Verdict rationale

The changed identity taxonomy does not expose secrets, widen Authentik superuser privilege, invent unsupported Checkmk roles, or introduce a destructive reconciliation path. The focused repository-only validator passed with no failures. Verdict: **CLEAR**.
