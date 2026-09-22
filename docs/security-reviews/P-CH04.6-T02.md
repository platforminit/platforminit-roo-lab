# Security Review — P-CH04.6-T02

- Task: `P-CH04.6-T02` — Preserve identity ownership during Argo CD SSO reconciliation
- Reviewer: `platforminit-owasp-reviewer`
- Scope: the three changed CH04.6 files only, plus the supplied focused evidence
- Verdict: **CLEAR**

## Review conclusion

The change is security-safe for the bounded acceptance criteria. The binding gate fails closed on missing or tampered taxonomy, duplicate/undeclared groups, superuser groups, foreign consumer ownership, surrounding whitespace, and policy-injection characters. The CH04.6 path consumes the CH04.5 group by exact-name lookup and does not issue group mutations. Ownership stamps are required before binding and the complete attribute bag is compared after membership convergence. RBAC is read back after apply and requires exactly one expected admin binding, `role:readonly` default policy, and the `groups` scope.

No new secret or credential handling was introduced beyond existing required runtime references. Changed code uses presence-only checks and redaction paths; reviewed evidence contained no secret values, credentials, or unapproved production scope.

## Findings by risk

### RBAC injection and privilege broadening — CLEAR

[`validate_argocd_admin_group_binding()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:271) applies the allow-list `^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$`, rejects surrounding whitespace, requires exactly one taxonomy entry, requires non-superuser status, and restricts consumer chapters to `platform` or `CH04.6` ([`ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:294)). The static evidence repeats accepted and rejected fixtures, including comma and newline injection, with deterministic results.

[`verify_argocd_rbac_mapping()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1112) requires the sole admin-role group line to equal the expected mapping, requires `policy.default` to remain `role:readonly`, and requires the `groups` scope ([`ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1136)). Additional non-admin group mappings are logged as narrower mappings, not treated as admin grants.

### CH04.5 ownership and fail-open behavior — CLEAR

[`require_authentik_admin_group()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:632) fails on missing ownership stamps, foreign `platforminit_managed_by`, disallowed consumer chapter, superuser groups, and parent inheritance. [`assert_group_ownership_preserved()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:717) performs a post-convergence read and hard-stops on any changed, added, or removed attribute key. The ownership harness evidence reports 10/10 controls passing, including cleared and overwritten stamp detection and zero non-GET calls.

The validator similarly promotes absent or foreign ownership data to blocking failures ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:781)). No attribute values are echoed as part of failure diagnostics; only attribute key names are reported.

### Taxonomy trust boundary — CLEAR

The gate requires the taxonomy file to exist, be valid JSON, have the expected CH04.5 management owner, and contain exactly one matching group ([`ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:323)). Missing or malformed taxonomy is a hard failure. The static validator cross-checks taxonomy constants and mutated management, superuser, and consumer fixtures ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:231)).

### Static validator isolation — CLEAR

The `--static` dispatch occurs before the first live `kubectl` use ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:402)). Supplied static evidence reports `STATIC_NO_LIVE_ACCESS` and 31 controls with zero failures. The prefix negative-control evidence is intentionally a stale/truncated pre-change artifact and is not evidence against the reviewed working tree; it is superseded by the complete static run.

### Secret, credential, and evidence exposure — CLEAR

The changed script retains key-name and value redaction for remote response diagnostics ([`ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:420)). The validator checks secret presence without printing values ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:883)). Review of the changed diff and supplied evidence found no secret values, real credentials, or production mutation scope.

## Residual risk and limitations

- Live/deployed proof remains unavailable because the supplied live validator evidence reports `KUBECTL_UNAVAILABLE`/an unhealthy rollout; no live pass is claimed.
- Live execution of the RBAC read-back and Authentik ownership checks was not available offline; their repository/static assertions and ownership harness passed.
- Drifted environments now hard-stop on extra admin mappings, non-readonly defaults, missing groups scope, or unstamped/foreign-owned groups. This is an intentional fail-closed availability impact, not a privilege-broadening defect.
- Pre-existing out-of-scope risks remain unchanged, including legacy `kubectl -p` argv exposure, prose-dependent shell redaction, legacy-key warn-vs-remove policy, and README drift.

## Evidence reviewed

- `git diff --check`: passed.
- `P-CH04.6-T02-static-validator.log`: 31 controls, 0 failures.
- `P-CH04.6-T02-ownership-harness.log`: 10 controls, 0 failures.
- Prefix logs: treated as stale negative-control artifacts because they fail to include the reviewed implementation markers.
- `P-CH04.6-T02-live-validator.log`: unavailable live proof; no fabricated success.

## Verdict

**CLEAR** — no blocking or review-required security finding introduced by this bounded change. Controller transition is recorded separately through `taskctl security`.
