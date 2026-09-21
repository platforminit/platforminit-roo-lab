# Review: P-CH04.6-T01

- **Task:** Audit the existing Authentik OIDC provider contract for Argo CD
- **Reviewer:** `platforminit-openai-reviewer`
- **Base / commits:** `8371154..HEAD` (`4b9fa38`, `fbf22de`)
- **Verdict:** `request_changes`

## Consolidated finding

### P1 — Authentik API error handling can disclose the client secret

[`request()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:251) catches an HTTP error and includes the complete response body in the raised exception at [`line 260`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:260). The same request helper sends `provider_payload`, which includes `client_secret` at [`line 501`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:501). If Authentik echoes submitted fields in a validation/error response, the uncensored body can reach workflow logs through the Python exception/traceback. This violates the task's secret-safety acceptance criterion even though the normal success path redacts values.

Fix the error path to log only HTTP status and a sanitized/non-secret error summary, or explicitly redact secret-bearing fields before raising. Add a focused negative test/harness assertion that an error response containing a client-secret value cannot appear in output.

## Acceptance-criteria assessment

1. **Provider/application contract:** Satisfied by the changed runbook and reconciliation/validator contract. The provider and application are unique, linked, and use the existing Authentik-to-Argo-Dex path.
2. **Issuer, redirects, scopes, and secret references:** Substantially satisfied. The implementation derives the issuer from `AUTHENTIK_BASE_URL`, checks discovery, enforces strict redirect entries, checks all four scopes and mappings, and checks key presence/reference without normally printing values. The P1 error-path disclosure prevents approval.
3. **Reuse of existing implementation:** Satisfied. The patch retains the existing CH04.6 script, validator invocation, four template anchors, and Dex-backed `argocd-cm` path; no parallel integration path was added.

## Evidence run

- Environment/branch gate: WSL confirmed; branch is `batch/platform-ch04-6-oidc-contract-audit`; working tree was clean before the report write.
- `git diff --check 8371154..HEAD -- <three changed files>`: pass.
- `bash -n` on both changed scripts: pass.
- Offline contract harness: pass, six controls (`6/6`), including secret-value non-disclosure and negative cases for missing redirect, missing CH04.5 group, duplicate provider path, and symmetric signing.
- `bash platform/identity/validate/ch04-5-validate-identity-model-contract.sh`: pass (`41` pass, `0` warn, `0` fail).
- `bash platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh`: pass (`27` pass, `0` warn, `0` fail).
- Live CH04.6 validator was not treated as passing; the expected WSL result is `FAIL | AUTHENTIK_ROLLOUT` because `kubectl` is unavailable.

## Residual risks and follow-ups

- No live cluster/runtime evidence exists; the future `04.6` workflow run remains required.
- CH04.6 now consumes the CH04.5 group read-only and fails closed when it is absent. The runbook ordering and CH04.5 remedy are documented consistently.
- Unconditional provider/application `PATCH` is convergent but not write-free. It is acceptable for this task; operational audit noise remains a residual risk.
- The validator's documented `WARN` behavior for Authentik fields not serialized by a deployed API version can reduce drift detection. The security reviewer should assess whether version-specific compatibility needs an independent proof or stricter minimum API contract.
- [`platform/identity/README.md`](../../platform/identity/README.md:86) still describes the retired `oidc.authentik.clientSecret` key. This is an out-of-scope documentation follow-up, not a separate blocker for this task.

---

# Rework addendum — round 2 (`platforminit-deepseek-coder`)

- **Stage:** implementation (rework) for `P-CH04.6-T01`, addressing the single P1 in the verdict above.
- **Branch:** `batch/platform-ch04-6-oidc-contract-audit` (not switched); review base `8371154`; pre-rework head `fbf22de`.
- **Round-1 content above is preserved verbatim.** This addendum only records the defect, the fix, the new negative control and the re-run evidence.
- **Scope actually changed:** [`ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1) (primary fix), [`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:1) (operator-visible behaviour), this evidence file, and `tasks/**` controller state. The validator and `platform/identity/integrations/argocd/**` were **not** touched.

## R1. Defect (restated precisely)

[`request()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:366) raised
`RuntimeError(f"{method} {path} failed with HTTP {exc.code}: {body}")` with the complete
Authentik response body, while the reconciliation submits `provider_payload` containing
`client_secret`. An Authentik validation/error response that echoes submitted fields
printed the client secret into the workflow log through the Python traceback. The same
class of exposure existed on the bash side, where remote response bodies were echoed
raw (the `dex.config` dump redacted only the single literal key `clientSecret`).

## R2. Fix

**Python side — key-name redaction plus value redaction** (helpers at
[`line 293`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:293) onward,
[`safe_response_body()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:349)):

1. `is_secret_key()` redacts any value whose key name matches a credential marker
   (`client_secret`/`clientSecret`, `secret`, token, authorization, password,
   credential, api/private key) and withholds the whole `attributes` bag, because
   Authentik echoes provider/group attributes there and their keys are arbitrary.
2. `redact_field()` walks JSON responses recursively, keeps every **field name** and
   replaces only credential-bearing values with `<redacted>`; the response is re-emitted
   as sorted JSON, so operators still see which field failed.
3. `known_secret_values()` + `redact_secret_values()` scrub the credential values this
   process holds (submitted client secret, Authentik API token) from every rendered
   string, so a secret that Authentik repeats under an unexpected key is still not
   printed.
4. A non-JSON error body is no longer eligible for printing at all: it is summarised as
   `<non-JSON body withheld: N bytes, field names unavailable>`.
5. The success path was hardened the same way: a 200 response that is not JSON now
   raises a sanitized `RuntimeError` instead of an unhandled decode error.

**Bash side — one shared redaction contract**
([`redact_secret_fields()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:64),
key pattern at [`line 62`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:62)),
applied to every path in the script where a response body or payload reaches
stdout/stderr:

| Path | Before | After |
|---|---|---|
| In-cluster discovery probe output | `echo "${probe_output}" >&2` | [`line 762`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:762) filtered through `redact_secret_fields` |
| `kubectl apply` response body | printed raw | [`line 852`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:852) filtered |
| `dex.config` summary dump | one literal key (`clientSecret`) redacted | [`line 873`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:873) same shared filter, so every credential key is covered |
| `argocd-server` log tails (3 call sites) | printed raw | [`lines 1015-1020`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1015) filtered |
| `kubectl get events` tail | printed raw | [`line 1028`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1028) filtered |

Redaction is by key name and always removes the **whole** value: a partially matched
token would leak its remainder. Rule order is deliberate (`Bearer` scheme first, then
compound container values, then quoted values, then the bare value to end of line), which
is why an echoed JSON body and an `Authorization: Bearer …` line both lose their value.
Trade-off, documented in the runbook: the remainder of a line that carries a credential
key is withheld with it, and key names (what an operator diagnoses by) always survive.

Reviewed and deliberately unchanged (no credential can reach them): the reconciliation's
captured payload variables (`patch_payload`, `next_oidc`, `cm_patch_payload` are piped to
`kubectl`, never echoed), the emitted `print()`/`log()` lines that contain only object
`pk`s, scope/mapping/group/user names, `kubectl get deploy|rs|pods -o wide` status output,
and `argocd-secret` key **presence** checks (`grep -q`, no output).

## R3. New negative control (offline, same evidence channel)

The round-1 harness was extended, not replaced:
`/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py` now drives **11** controls.
Controls 1-6 are the unchanged validator/PYCONTRACT controls. The new controls extract the
reconciliation `PY` block, stub `urllib.request.urlopen` so the first call raises
`HTTPError` whose body echoes the submitted payload, and capture the exception text
exactly the way a Python traceback would print it into the workflow log:

- `rework-7-error-body-client-secret-not-printed` — the echoed `client_secret` sentinel **and** the API-token sentinel echoed inside the `attributes` bag are absent from output, while the failure still raises;
- `rework-8-error-still-diagnosable` — `HTTP 400` and the non-secret field name `redirect_uris` still reported;
- `rework-9-non-json-body-withheld` — a non-JSON body containing the sentinel is withheld by size;
- `rework-10-token-echo-under-unexpected-key` — the API token echoed under `detail` is scrubbed by value, while `detail`/`HTTP 400` survive;
- `rework-11-bash-diagnostic-redactor` — `redact_secret_fields` run as the real pipe filter over nine leak vectors (YAML key, JSON quoted key, `KEY=value`, `server.secretkey`, `attributes` bag, `Authorization: Bearer`, prose `client secret …`); no sentinel survives and non-secret diagnostics (including `client_id`, `detail:` and `kubectl` output lines) are preserved.

The controls are shown to be real detectors: the harness accepts `HARNESS_SCRIPT`, and
running the same file against the **pre-fix** revision (`git show 4b9fa38:…`) fails
`rework-7`, `rework-9`, `rework-10` and `rework-11`.

## R4. Exact commands and observed results

```bash
git branch --show-current
# batch/platform-ch04-6-oidc-contract-audit

bash -n platform/identity/scripts/ch04-6-enable-argocd-sso.sh
# rc=0

python3 -  # compile every heredoc block in the changed script
# PY_BLOCKS_COMPILE_OK count=5

grep -n 'ARGOCD_ADMIN_GROUP="\${ARGOCD_ADMIN_GROUP:-' platform/identity/scripts/ch04-6-enable-argocd-sso.sh
# 82:ARGOCD_ADMIN_GROUP="${ARGOCD_ADMIN_GROUP:-PlatformInit Admins}"   (default preserved)

grep -n 's|__[A-Z_]*__|' platform/identity/scripts/ch04-6-enable-argocd-sso.sh
# __BASE_DOMAIN__, __AUTHENTIK_OIDC_ISSUER__, __ARGOCD_OIDC_CLIENT_ID__, __ARGOCD_ADMIN_GROUP__ (all four sed anchors preserved)

git diff --check
# required validator: rc=0, no output

python3 /tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py
# PASS | control-1-correct-provider                  | rc=0 | PASS=28 WARN=0 FAIL=0
# PASS | control-2-secret-value-never-printed        | rc=0 | client_secret sentinel absent from output
# PASS | negative-3-missing-redirect-uri             | rc=1 | fails closed
# PASS | negative-4-missing-ch04-5-group              | rc=1 | fails closed
# PASS | negative-5-duplicate-provider-path           | rc=1 | fails closed
# PASS | negative-6-symmetric-signing-risk            | rc=1 | fails closed
# PASS | rework-7-error-body-client-secret-not-printed| rc=1 | echoed client_secret and the attributes-bag token never reach the error output while the failure still raises
# PASS | rework-8-error-still-diagnosable             | rc=1 | status code and non-secret field names still reported
# PASS | rework-9-non-json-body-withheld              | rc=1 | non-JSON body summarised by size
# PASS | rework-10-token-echo-under-unexpected-key    | rc=1 | credential under a non-secret key scrubbed by value
# PASS | rework-11-bash-diagnostic-redactor           | rc=0 | removed every sentinel, kept non-secret context
# harness overall: PASS (11 controls)   rc=0

git show 4b9fa38:platform/identity/scripts/ch04-6-enable-argocd-sso.sh > /tmp/platforminit-evidence/P-CH04.6-T01-prefix-reconciler.sh
HARNESS_SCRIPT=/tmp/platforminit-evidence/P-CH04.6-T01-prefix-reconciler.sh python3 /tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py
# FAIL | rework-7  | echoed client_secret reached the error output          <- pre-fix defect reproduced
# FAIL | rework-9  | non-JSON body printed raw
# FAIL | rework-10 | token echo printed raw
# FAIL | rework-11 | redact_secret_fields helper is not present
# harness overall: FAIL (11 controls)   rc=1

bash platform/identity/validate/ch04-5-validate-identity-model-contract.sh
# pass=41 warn=0 fail=0   rc=0
bash platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh
# pass=27 warn=0 fail=0   rc=0

bash platform/identity/validate/ch04-6-validate-argocd-sso.sh
# FAIL | AUTHENTIK_ROLLOUT | authentik-server rollout is not healthy   rc=1
# (not treated as passing: kubectl is absent in this WSL workspace — command -v kubectl -> KUBECTL_NOT_AVAILABLE)
```

Reused unchanged evidence: the six round-1 harness controls and the validator/PYCONTRACT
`bash -n` result. Re-run because this change invalidates them: both CH04.5 validators,
which read [`ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1)
statically (template anchors, `ARGOCD_ADMIN_GROUP` default, group-payload advisory) — both
still report `41/0/0` and `27/0/0`.

Evidence artifacts (outside the repository, transient):

- `/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py` (extended, 11 controls)
- `/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness-rework.log`
- `/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness-prefix.log`
- `/tmp/platforminit-evidence/P-CH04.6-T01-ch04-5-model-contract-rework.log`
- `/tmp/platforminit-evidence/P-CH04.6-T01-ch04-5-cross-consumer-rework.log`
- `/tmp/platforminit-evidence/P-CH04.6-T01-live-validator-rework.log`

## R5. Acceptance criteria after rework

| Criterion | Status | Evidence |
|---|---|---|
| 1. Provider/application contract explicit and current | MET (unchanged) | Round-1 evidence retained; this rework does not alter the contract. |
| 2. Issuer, redirect URI, scopes and secret references are validated without exposing secret values | MET | Round-1 checks unchanged **plus** the P1 error path fixed on both sides and proven by `rework-7/9/10/11`; the sentinel is absent from every output path touched (`request()` error and non-JSON paths, probe echo, `kubectl apply` echo, `dex.config` summary, pod-log tails, events tail). |
| 3. Reuses the existing implementation instead of a parallel OIDC path | MET (unchanged) | No new script, validator, template, workflow or provider path; no change under `platform/identity/integrations/argocd/**`. |

## R6. Residual risk the reviewer and the security reviewer must check

1. **Live evidence still does not exist.** All rework evidence is offline/static; the live
   validator cannot run here (`AUTHENTIK_ROLLOUT`, no `kubectl`). The next real
   `04.6 - Enable Argo CD SSO` run is still the only live proof.
2. **Bash redaction is key-name based, not JSON-aware.** A credential echoed in free prose
   under no credential-like key and with a value the process does not hold (for example a
   *returned* secret that differs from the submitted one and whose key is not
   credential-like) would not be caught by the bash filter. The Python error path is not
   affected: it redacts by key and additionally by known value. Worth a security-reviewer
   opinion on whether the pod-log tail path needs value-level knowledge too.
3. **Diagnostics cost of the fix.** A line that carries a credential key loses the rest of
   that line; a JSON error body is re-emitted sorted, with secret values (and the whole
   `attributes` bag) replaced. Operators keep the status code and field names, but a
   reviewer should confirm this is acceptable troubleshooting UX.
4. **`client_secret` still travels through argv.** The script patches
   `dex.authentik.clientSecret` via `kubectl … -p "<base64 payload>"`, so the value is
   visible in the process table on the host. Out of scope for this P1 (no output path) and
   unchanged by this rework; flagged for the security reviewer.
5. **`docs/reviews` remains outside the controller `allowedFiles`.** Same exception as
   round 1, required by the task's evidence path; unchanged.

## R7. Controller transition

This rework child records exactly one transition and routes nothing onward:

```text
python3 tools/task_controller/taskctl.py submit P-CH04.6-T01 --actor platforminit-deepseek-coder
```

Round-1 findings above were not altered, no branch was switched, no `git push` was
performed, and no controller state was edited by hand.
