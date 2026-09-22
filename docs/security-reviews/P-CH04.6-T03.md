# Security Review — P-CH04.6-T03

- Task: `P-CH04.6-T03` — Validate Argo CD SSO login/logout and fallback contract
- Reviewer: `platforminit-owasp-reviewer`
- Scope: the two changed CH04.6 files, plus directly required templates/contracts and supplied focused evidence
- Verdict: **CLEAR**

## Review conclusion

The bounded change is security-safe for the stated acceptance criteria. The repository-only validator covers the login connector, redirect/logout origin, strict redirect allow-list payload, session-key reference, OIDC scopes, group claim/RBAC contract, break-glass documentation, and the explicit boundary between static validation and a human-approved browser test.

No new credential, token, password, client secret, internal secret value, or unsafe authentication bypass was introduced. The validator uses presence-only secret checks and secret references; it does not print, hash, or copy secret values. The local Argo CD `admin` path is documented as emergency recovery and remains operator-visible rather than silently weakening normal authentication.

## Findings by risk

### Secret and evidence exposure — CLEAR

The changed validator documents and implements presence-only checks for Kubernetes secret keys and uses the Dex reference `$dex.authentik.clientSecret`, not an inline value ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:49), [`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:693)). The runbook names only secret names and key names, explicitly prohibits repository/log storage of the admin password, and states that the validator never reads secret values ([`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:62), [`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:362)). Reviewed changed-scope diff and supplied evidence contained no secret values.

### Read-only and fail-closed behavior — CLEAR

`--static` dispatches before live `kubectl` use and proves no cluster or network access ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:682), [`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:454)). Static controls fail on missing inputs, altered contract literals, missing documentation anchors, weakened separation wording, changed redirect payload, or non-deterministic gate outcomes ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:172), [`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:519)). The live path is read-only and uses blocking `FAIL` behavior for missing prerequisites and contract mismatches; no mutation workflow was run.

### Redirect allow-list and open-redirect boundary — CLEAR

The static validator requires exactly three strict entries—browser callback, CLI callback, and logout—with two authorization types, one logout type, and frontchannel logout ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:519)). The live contract compares the complete collection and rejects extras, duplicates, non-strict entries, malformed entries, and unexpected types ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:1168), [`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:1228)). Callback and logout URLs are required to remain on the `argocd-cm` `data.url` origin ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:719)). No wildcard, prefix, or regex loosening was found.

### OIDC claims and RBAC privilege boundary — CLEAR

The changed contract requires the Authentik groups scope and ID-token claims, while the existing bounded mapping remains one expected CH04.5-owned group to `role:admin` with a read-only default ([`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:122), [`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:782)). The static gate rejects superuser, foreign-consumer, undeclared, whitespace-padded, comma-injection, and newline-injection group names; the live checks reject missing/foreign ownership stamps, parent inheritance, extra admin bindings, and broader defaults ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:414), [`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:1019). No unverified header trust or privilege-broadening mapping was introduced.

### Break-glass, logout/session semantics, and live-test boundary — CLEAR

The runbook explicitly states that local `admin` is recovery-only, that its password belongs in an operator password store, and that recovery is followed by reconciliation and focused validation ([`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:362)). Logout/session behavior, frontchannel logout, unchanged authorization, and deliberate session invalidation by `server.secretkey` rotation are documented ([`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:330)). Both validator output and runbook text state that static validation does not perform or prove browser login/logout and that live testing requires explicit human approval ([`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:114), [`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:376)).

## Residual risks and limitations

- Browser login/logout remains unobservable automatically; the required live SSO test is still a separately approved manual step and is not claimed by this review.
- Static separation proves emitted wording and repository contract, not operator comprehension; the runbook correctly assigns human approval and evidence responsibility.
- A `BASE_DOMAIN` or `argocd-cm` URL change must be applied consistently across deployment inputs and Authentik redirect entries; the validator fails closed on one-sided drift.
- Deployed objects remain unproven in this WSL workspace because no live cluster validation was run. This is an availability/evidence limitation, not a security approval for runtime state.
- The pre-existing retired client-secret patch wording in [`platform/identity/README.md`](../../platform/identity/README.md:78) is outside this task's allowed changed scope and is not introduced by this change.

## Evidence reviewed

- Environment and branch gate: WSL check passed; branch was `batch/platform-ch04-6-sso-validation`; changed scope matched the two authoritative non-state paths plus controller/generated state.
- `git diff --stat dev...HEAD`: no unexpected non-state path in the branch diff summary.
- `git diff --check dev...HEAD`: passed.
- `bash platform/identity/validate/ch04-6-validate-argocd-sso.sh --static`: 39 controls, 0 failures.
- Supplied static runs 1–3: each reported 39 controls and 0 failures with the repository-only/live-test boundary note.
- Supplied focused and negative-control logs: reviewed as evidence context; no secret values observed.
- No infrastructure workflow, Kubernetes mutation, Authentik mutation, DNS/Cloudflare operation, or live browser SSO test was performed.

## Verdict

**CLEAR** — no blocking or review-required security/privacy/release finding was introduced by this bounded change. The required controller transition is recorded separately through `taskctl security`.
