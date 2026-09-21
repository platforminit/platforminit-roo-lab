# Security Review — P-CH04.6-T01

- **Task:** Audit the existing Authentik OIDC provider contract for Argo CD
- **Stage:** security-review
- **Verdict:** REVIEW_REQUIRED
- **Review scope:** `platform/identity/scripts/ch04-6-enable-argocd-sso.sh`, `platform/identity/validate/ch04-6-validate-argocd-sso.sh`, and `platform/identity/docs/ch04-6-argocd-sso-runbook.md` as changed between `8371154..HEAD`.

## Finding

### SEC-01 — The read-only validator does not reject extra permissive redirect entries

- **Severity:** Medium; release/security contract gap, not an observed live exposure.
- **Location:** [`platform/identity/validate/ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:425-447), especially `redirect_registered()` at lines 429–437.
- **Issue:** The validator proves that each expected callback/logout URI exists with `matching_mode: strict`, but it does not assert that the provider’s complete `redirect_uris` collection contains only those three entries. An already-drifted provider containing an additional wildcard, prefix, or regex redirect can therefore pass all three redirect checks. This conflicts with the runbook’s explicit “no wildcard, prefix or regex matching” contract at [`platform/identity/docs/ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:36-42).
- **Why this matters:** A permissive extra redirect entry can create an OAuth redirect/open-redirect boundary that is not detected by the focused validator, even though the reconciliation writer normally replaces the list with the three strict entries at [`platform/identity/scripts/ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:633-639).
- **Required remediation:** In the validator, normalize and compare the complete live `redirect_uris` set against the exact three expected `(url, redirect_uri_type, matching_mode)` tuples; fail on any extra entry, any duplicate, any non-`strict` mode, or any unexpected redirect type. Add a focused offline regression fixture proving an extra wildcard/prefix/regex entry fails validation. Do not rely solely on the writer’s PATCH behavior.

## Accepted residual risks / non-blockers

1. **Credential in process arguments:** [`platform/identity/scripts/ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:193-216) passes the base64-encoded client-secret payload through `kubectl -p`. This can expose the encoded secret in the host process table to same-host observers. It is pre-existing at the reviewed base (`8371154`), not introduced by this task, and is accepted as a documented follow-up for the disposable development host; it is not accepted as a production security pattern. Remediation should move the patch payload through stdin or an equivalent mechanism that avoids secret-bearing argv.
2. **Bash redaction is key-name/prose dependent:** [`redact_secret_fields()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:64) cannot guarantee removal of a credential echoed in arbitrary prose unless the value is also one of the Python process’s known secret values. The Python path provides value substitution through [`known_secret_values()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:315) and [`safe_response_body()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:349); non-JSON bodies are withheld. Accepted follow-up because raw Authentik response bodies are not emitted and the known secret values are scrubbed.
3. **Legacy key warning:** The writer removes `oidc.authentik.clientSecret` at [`platform/identity/scripts/ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:218-227), while the validator currently warns rather than fails at [`platform/identity/validate/ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:139-146). This is accepted as a cleanup/drift follow-up only because the reconciliation path is authoritative; the validator should be strengthened if “exactly one” is a blocking invariant.
4. **Documentation drift outside scope:** [`platform/identity/README.md`](../../platform/identity/README.md:78-91) retains the old `oidc.authentik.clientSecret` description. It contains a reference, not a credential value, and is outside the three-file task scope; accepted as a documentation follow-up.
5. **Live validation:** The live validator was not proven in this WSL workspace because `kubectl` is unavailable; this is an evidence limitation, not an infrastructure mutation.

## Positive security evidence

- The changed files contain secret names/references only; no literal credential, token, private key, PEM/key material, kubeconfig content, or GitHub/DNS/Cloudflare secret was found.
- The Python diagnostic path uses [`is_secret_key()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:304), [`redact_field()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:333), and [`safe_response_body()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:349); non-JSON response bodies are withheld and JSON credential fields are replaced.
- The Dex path writes `dex.authentik.clientSecret`, removes the legacy direct-OIDC key, and uses only the `$dex.authentik.clientSecret` reference in `dex.config` at [`platform/identity/scripts/ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:210-227) and [`platform/identity/validate/ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:68-77,109-110).
- The group lookup is exact-name, rejects superuser/parent groups, and fails closed when absent at [`platform/identity/scripts/ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:464-495).
- Provider/application uniqueness, application-provider linkage, issuer derivation/discovery, asymmetric signing-key posture, scope mappings, and strict expected redirects are asserted in [`platform/identity/validate/ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:351-487). The extra-entry completeness gap is the exception recorded above.

## Commands and results

- `health` MCP: passed.
- `get_delivery_context` MCP for `P-CH04.6-T01`: passed; controller status was `needs_security_review`; changed scope was three non-state files.
- `git diff 8371154..HEAD -- <three changed paths>`: inspected; no out-of-scope product paths in the requested scope.
- `bash -n` on both changed shell files: passed.
- `git diff --check 8371154..HEAD -- <three changed paths>`: passed.
- Live `bash platform/identity/validate/ch04-6-validate-argocd-sso.sh`: not runnable/proven because `kubectl` is unavailable; no infrastructure command was run.
- No workflow, Authentik, Kubernetes, DNS, Cloudflare, GitHub secret, or GitHub environment mutation was performed.

## Controller transition

The required transition is:

```bash
python3 tools/task_controller/taskctl.py security P-CH04.6-T01 --actor platforminit-owasp-reviewer --verdict review_required --report docs/security-reviews/P-CH04.6-T01.md
```
