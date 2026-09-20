# Security Review: P-CH04.5-T04B

- **Stage:** security-review
- **Reviewer:** `platforminit-owasp-reviewer`
- **Task:** `P-CH04.5-T04B — Make CH05 consume the canonical operations identity`
- **Branch:** `batch/platform-ch05-identity-consumer`
- **Verdict:** CLEAR

## Scope and evidence

Reviewed only the controller-confirmed changed paths:

- [`platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh`](../../platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh)
- [`platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh`](../../platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh)
- [`platform/observability/checkmk/README.md`](../../platform/observability/checkmk/README.md)

Directly required trust-boundary reference inspected read-only:

- [`platform/observability/manifests/templates/checkmk/checkmk-config.yaml`](../../platform/observability/manifests/templates/checkmk/checkmk-config.yaml)

Evidence reviewed:

- [`/tmp/platforminit-evidence/P-CH04.5-T04B-static-sso-validate.log`](/tmp/platforminit-evidence/P-CH04.5-T04B-static-sso-validate.log)
- [`/tmp/platforminit-evidence/neg-a.log`](/tmp/platforminit-evidence/neg-a.log)
- [`/tmp/platforminit-evidence/neg-b.log`](/tmp/platforminit-evidence/neg-b.log)
- [`docs/reviews/P-CH04.5-T04B.md`](../reviews/P-CH04.5-T04B.md)

Read-only checks performed:

1. MCP health and controller delivery-context reload for the active task.
2. Changed-file diff inspection and `git diff --check` against `dev`.
3. Focused inspection for trusted-header handling, credential exposure, command injection, destructive identity operations, static-mode bypasses, retired identities, and privilege broadening.
4. Focused static validation with `CH05_SSO_VALIDATE_MODE=static`; it passed and reported no cluster access or runtime mutation.
5. Evidence inspection of both negative static-validation cases; both failed closed as intended.

## Consolidated findings by severity

### Critical / High: none

No critical or high security finding was identified in the bounded change.

### Medium: none

- [`require_group()`](../../platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh:114) performs lookup-only resolution of the canonical group and rejects missing or slug-mismatched look-alikes. No group `POST` or group `PATCH` remains in the active SSO path.
- The only identity membership mutation is the intended user-membership [`PATCH`](../../platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh:152) after the canonical group has been resolved. This does not create, rename, re-attribute, or elevate the group.
- The Authentik token is read from the existing bootstrap Secret or environment and used in an in-memory request header. The changed path does not echo the token, include it in Markdown, write a token-bearing file, or broaden the requested token scope. Error output can expose API response bodies from Authentik, but no token value is interpolated into those messages.
- The auth-shim contract retains [`proxy_pass_request_headers off`](../../platform/observability/manifests/templates/checkmk/checkmk-config.yaml:45), clears `Authorization`, and explicitly maps the approved Authentik-derived identity to deterministic `X-Remote-User: cmkadmin`. The static assertions check the same manifest-level boundary rather than asserting a weaker or unrelated header contract.
- Static mode exits before any `kubectl` runtime branch and performs repository-only assertions. It does not accept a success result for unsupported modes, and the negative evidence shows failures for a forbidden group mutation pattern and a retired identity in the canonical model.

### Low / Informational: none requiring rework

The documentation accurately describes canonical CH04.5 ownership, CH05 lookup-only consumption, and the Authentik -> Traefik -> auth-shim -> Checkmk boundary. No secret value or operational credential is present in the changed Markdown.

## Residual risks accepted for this bounded task

1. CH04.5 remains `upsert-no-prune`; stale live look-alike or retired group slugs are not automatically deleted and can continue to cause CH05.3 to fail closed. Cleanup requires a separately governed task.
2. Retired-stack references outside the three changed paths remain outside this task's allowed scope.
3. The retired-name guard is intentionally location/scenario scoped; it protects the CH05.3 enable path and its static contract, not every historical repository reference.
4. The runtime enable script still performs intended Authentik provider/application/outpost reconciliation and Checkmk Secret creation. This is expected CH05.3 behavior, not an identity-group ownership bypass, and was not executed during this review.
5. The deterministic `cmkadmin` mapping remains a shared local administrator boundary until per-user Checkmk provisioning is introduced; Authentik forwardAuth remains the external authorization gate.

## Verdict rationale

The focused evidence demonstrates canonical operations-group consumption without parallel group ownership, no active CH05 SSO creation or consumption of retired Zabbix/OpenObserve groups, and a fail-closed static proof of the Authentik -> Traefik -> auth-shim consumer boundary. Credential handling and header minimization remain consistent with the security contract. Verdict: **CLEAR**.
