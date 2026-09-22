# Review — P-CH04.6-T03

## Verdict

**APPROVE** — the bounded implementation satisfies the three acceptance criteria based on the changed-files review and focused evidence. No correctness, integration, scope, idempotence, failure-mode, or operator-UX defect was found that requires rework before security review.

## Scope and lifecycle

- Task: `P-CH04.6-T03` — Validate Argo CD SSO login/logout and fallback contract.
- Reviewed branch: `batch/platform-ch04-6-sso-validation`.
- Changed product scope is exactly [`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:1) and [`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:1); controller-owned `tasks/**` changes were not treated as product code.
- WSL, identity, branch, status, remote, and bounded diff checks were performed. No additional product paths were introduced.
- `git diff --check` passed.
- The controller was at `needs_review` before the verdict and must be advanced only by the required `taskctl review` command.

## Acceptance criteria

### 1. Focused validation covers expected OIDC login, redirect and RBAC contract — MET

The static validator asserts the reconciler's public URL, provider name, browser and CLI callbacks, logout path and four scopes through [`STATIC_OIDC_CONTRACT_DEFAULTS`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:464). [`STATIC_LOGIN_REDIRECT_RBAC_PARITY`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:484) checks that validator and reconciler literals agree and that callback/logout URLs remain on the Argo CD origin. [`STATIC_STRICT_REDIRECT_ALLOWLIST_PAYLOAD`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:519) requires exactly three strict entries, two authorization entries, one logout entry, and frontchannel logout. [`STATIC_DEX_LOGIN_SESSION_WIRING`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:539) checks the Authentik connector, secret reference, groups claim, direct-OIDC removal, and stable session key. The rendered [`argocd-cm`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:559) and RBAC template checks are deterministic and retain the expected scopes, single admin binding, and read-only default policy.

The live branch remains read-only and fails closed: without `kubectl`, the supplied focused evidence returned `AUTHENTIK_ROLLOUT` failure with rc 1 rather than silently passing. No live browser claim is made.

### 2. Logout/session behavior and emergency local access are explicitly documented — MET

The runbook's [`Login and logout session contract`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:330) documents the login connector and callbacks, frontchannel logout, session signing key, logout effects, authorization persistence, and deliberate session invalidation on key rotation. [`Break-glass and emergency local access`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:362) keeps the local Argo CD `admin` account as the Authentik-independent recovery path, protects its credential handling, and points to the crash-loop recovery path.

[`STATIC_RUNBOOK_LOGIN_LOGOUT_DOC`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:600) guards these documentation anchors and passed.

### 3. Repository-only validation remains distinct from any human-approved live SSO test — MET

The runbook explicitly separates the static command and its repository-only proof from the approved browser test in [`Repository-only validation versus the human-approved live SSO test`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:376). The validator prints a boundary note on both successful and failed static summaries and records the live boundary in the live path. [`STATIC_LIVE_TEST_SEPARATION`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:615) requires the wording, runbook reference, and both summary emissions. This correctly documents that static validation cannot observe browser login/logout; it does not pretend to automate that observation.

## Integration, regression, and failure-mode review

- Scope stays within the two allowed product files; no infrastructure workflow, cluster, DNS, Authentik, or secret mutation was performed.
- The file-based token checks are a real pipefail/SIGPIPE fix: the script writes comment-stripped reconciler code to a temporary file at [`static_code_file`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:195), then greps that file. The assertions remain explicit and the negative-control harness showed they reject removed session/documentation/redirect/scope contracts.
- Repeated static runs are deterministic: the supplied three-run evidence is byte-identical, each reports 39 controls and zero failures, and the independent run also returned rc 0 with the same 39-control summary.
- Unsupported arguments fail with rc 2. Live mode without `kubectl` fails closed with rc 1 at the rollout prerequisite.
- Negative controls ran against a throwaway repository copy and rejected weakened runbook anchors, loosened strict redirect mode, removed groups scope, weakened the boundary note, and narrowed the scope contract. The workspace tree remained unchanged apart from the controller/product changes already under review.
- URL derivation and redirect/logout origin checks appropriately require coordinated changes to `argocd-cm`, provider redirect configuration, and deployment inputs when `BASE_DOMAIN` changes.
- No secret values appear in the changed additions, focused evidence used here, or this report.
- The pre-existing [`README.md`](../../platform/identity/README.md:78) statement about the retired `oidc.authentik.clientSecret` path remains outside this task's allowed files and is not introduced by this patch; it is a follow-up documentation risk.

## Evidence reused and commands run

- `pwd && grep -Eiq "microsoft|wsl" /proc/version && echo WSL_OK && id -un && git branch --show-current && git status --short && git remote -v && git diff --stat dev...HEAD`: WSL_OK; branch `batch/platform-ch04-6-sso-validation`; exactly two product files plus controller state modified.
- `bash platform/identity/validate/ch04-6-validate-argocd-sso.sh --static`: rc 0; `static validation: PASS (39 controls, 0 failures)`.
- `git diff --check`: rc 0; clean.
- `/tmp/platforminit-evidence/P-CH04.6-T03-focused-validation.log`: bash syntax clean; three static runs rc 0 and byte-identical; unsupported arg rc 2; live path rc 1 without `kubectl`; diff check clean.
- `/tmp/platforminit-evidence/P-CH04.6-T03-negative-controls.log`: throwaway-copy negative controls rejected all targeted weakened contracts; workspace tree remained unchanged by the harness.
- `/tmp/platforminit-evidence/P-CH04.6-T03-static-run1.out`, `-run2.out`, `-run3.out`: each reports 39 controls and zero failures with identical output.
- `/tmp/platforminit-evidence/P-CH04.6-T03-taskctl-submit.log`: confirms the prior submit attempt did not advance state because the task was already `needs_review`; no tracker hand-edit was relied upon.

## Consolidated findings

No review-blocking findings.

## Residual risk

Browser login/logout cannot be observed by repository validation and still requires an explicitly human-approved live test with its own evidence. The static boundary control proves that the note is emitted and documented, not that an operator read it. The live `kubectl` branch remains unobserved in this WSL workspace. The `BASE_DOMAIN` coordination requirement and the pre-existing README drift are credible documented follow-up risks, not regressions introduced by this task.
