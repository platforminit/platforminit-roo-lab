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

---

# Round-2 reviewer verdict (`platforminit-openai-reviewer`)

- **Review scope:** rework diff `fbf22de..HEAD`; changed non-state files remain the two files shown by the diff, with `platform/identity/validate/ch04-6-validate-argocd-sso.sh` unchanged and inspected for compatibility. The requested three-file scope remains within the controller budget; no product source or validator file was modified by this review.
- **Verdict:** **APPROVE**

## Findings

No remaining correctness, integration, regression, idempotence, workflow-UX, or acceptance-criteria defect was found in the changed scope.

The round-1 P1 is genuinely closed. The Python `request()` error path no longer interpolates the raw Authentik body. JSON responses are recursively redacted by credential-bearing key name and known client-secret/API-token values; non-JSON bodies are withheld by size; and non-JSON successful responses become sanitized errors. The Bash diagnostic filter is applied to each newly identified remote-response/log echo path. Captured payload variables are only sent to `kubectl` and are not echoed. The output-sink inspection found no remaining raw response-body echo that bypasses either the Python sanitizer or the Bash filter.

Acceptance criteria remain satisfied:

1. The provider/application contract remains explicit and current; the round-2 changes do not regress the issuer, redirect, scope, signing, provider/application-link, or single-provider assertions.
2. Issuer, strict redirect URIs, scopes, and secret references remain validated without printing secret values. The P1 error-path and diagnostic-output controls now cover the previously unprotected paths.
3. The existing CH04.6 Authentik-to-Argo-Dex implementation remains the only OIDC path; no parallel provider, validator, template, or workflow path was introduced.

The unchanged validator is justified: the rework changes only reconciliation error handling and diagnostic filtering, while the validator's contract assertions and read-only behavior are unaffected. The CH04.5 validators were rerun because they statically consume the changed reconciler and both retained their passing results.

## Evidence independently verified

- WSL/environment and branch gate passed; current branch is `batch/platform-ch04-6-oidc-contract-audit`.
- `git diff --check fbf22de..HEAD -- <three changed paths>`: rc 0.
- `bash -n platform/identity/scripts/ch04-6-enable-argocd-sso.sh`: rc 0.
- `python3 /tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py`: 11 controls PASS overall, rc 0.
- Anti-vacuity: the same harness with `HARNESS_SCRIPT` pointing to the `4b9fa38` pre-fix script: overall FAIL, rc 1; rework controls 7, 9, 10 and 11 failed as expected while the unchanged controls passed.
- The recorded CH04.5 evidence is reused: identity-model-contract `pass=41 warn=0 fail=0`, and cross-consumer `pass=27 warn=0 fail=0`; no inspection finding invalidated that evidence.
- The live CH04.6 validator remains intentionally unpassed: `FAIL | AUTHENTIK_ROLLOUT`, rc 1, because `kubectl` is unavailable in this WSL workspace.

## Residual risks handed to security review / release

- Live cluster/runtime behavior remains unproven and requires the future approved workflow run.
- Bash redaction is key-name based and not JSON-aware; unknown returned credentials in free prose under non-credential-like keys can remain a residual concern. Python's API error path additionally scrubs values held by the process.
- Diagnostic usability is intentionally reduced for credential-bearing lines, and JSON error bodies are re-emitted with values replaced.
- The client secret remains present in a `kubectl -p` argument and may be visible in the host process table; this is unchanged and is handed to the security reviewer as a separate exposure concern, not a blocker for this output-disclosure P1.
- `docs/reviews/**` is the mandated evidence exception outside controller `allowedFiles`.
- The stale `platform/identity/README.md` statement about `oidc.authentik.clientSecret` remains an out-of-scope follow-up.

## Required controller transition

The exact transition command to record this verdict is:

```bash
python3 tools/task_controller/taskctl.py review P-CH04.6-T01 --actor platforminit-openai-reviewer --verdict approve --report docs/reviews/P-CH04.6-T01.md
```

---

# Security-remediation addendum — round 3 (`platforminit-deepseek-coder`)

- **Stage:** implementation (security remediation) for `P-CH04.6-T01`, addressing the single `SEC-01`
  finding of [`docs/security-reviews/P-CH04.6-T01.md`](../../docs/security-reviews/P-CH04.6-T01.md:10).
- **Branch:** `batch/platform-ch04-6-oidc-contract-audit` (not switched); change base `8371154`;
  pre-remediation head `734dcc7`.
- **Round-1 and round-2 content above is preserved verbatim**; no earlier finding was removed, rewritten
  or downgraded.
- **Changed non-state files (2):** [`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:1)
  (primary fix) and [`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:40)
  (contract text now states the completeness assertion). This evidence file, the previously untracked
  security report and `tasks/**` complete the commit. The reconciliation script and
  `platform/identity/integrations/argocd/**` were **not** touched, so the round-1 P1 fix at
  [`request()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:366) is untouched and cannot
  regress; no controller state was edited by hand.

## S1. Defect (restated precisely)

`SEC-01` (Medium): the validator's redirect assertions were inclusive only. `redirect_registered()` proved
that each expected callback/logout URI existed with `matching_mode: strict`, but nothing asserted that the
provider's complete `redirect_uris` collection contained **only** those three entries. An already-drifted
provider carrying an extra wildcard/prefix/regex redirect therefore passed all three redirect checks,
contradicting the runbook contract "no wildcard, prefix or regex matching". The validator must not depend
solely on the reconciliation writer's `PATCH` having replaced the list.

## S2. Fix (one assertion path, still inside `PYCONTRACT`)

The existing `PYCONTRACT` block was extended — no second parsing path, no new validator, no new script:

1. The three expected contract targets are declared once at
   [`expected_redirect_targets`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:438) and
   normalized through `normalize_redirect_url()` (trailing-slash insensitive, the normalization the entry
   matcher always applied).
2. Each live entry is normalized into a comparable `(url, redirect_uri_type, matching_mode)` tuple by
   `redirect_tuple()`; a non-dict entry becomes a malformed tuple, so it fails closed instead of being
   skipped as before.
3. The three unchanged per-URI checks now read from that tuple set via
   [`strict_entry_registered()`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:476), so
   their check codes, `PASS | CODE | detail` shape and pass criteria are preserved.
4. The completeness assertion at
   [`AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:489)
   compares the **full sorted rendered set** live-vs-expected and fails on any of: extra entry, duplicate
   entry, `matching_mode` other than `strict`, `redirect_uri_type` outside `authorization`/`logout`. The
   failure detail lists each reason with the offending tuples (contract URLs and modes only — no secret
   value is read, printed or hashed). The check emits `PASS` at
   [`line 508`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:508), emits `FAIL` and
   appends the check name to `failures` at
   [`line 529`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:529), so the block's
   existing `exit 1` fail-fast and the validator's invocation contract
   (`bash platform/identity/validate/ch04-6-validate-argocd-sso.sh`, `0` = all PASS/WARN, `1` = first FAIL)
   are unchanged.
5. The file header documents the new completeness assertion, and the runbook states the same invariant for
   operators at
   [`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:44).

Expected set (unchanged from the reviewed contract): `(https://argocd.<base>/api/dex/callback, authorization, strict)`,
`(https://localhost:8085/auth/callback, authorization, strict)`, `(https://argocd.<base>/logout, logout, strict)`.

## S3. New regression controls (same offline evidence channel)

The round-1/round-2 harness was extended, not replaced, at the same path
`/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py` (transient, outside the repository). It now
drives **18** controls: the unchanged `control-1..6`, `negative-3..6` and `rework-7..11`, plus seven new
`SEC-01` controls that feed a stubbed Authentik API model into the validator's own `PYCONTRACT` block:

| Control | Fixture | Expected |
|---|---|---|
| `remediation-12-extra-wildcard-redirect-fails` | three strict entries + `https://*.evil.example/cb`, `strict` | FAIL closed |
| `remediation-13-extra-prefix-redirect-fails` | three strict entries + `https://argocd.<base>/api`, `prefix` | FAIL closed |
| `remediation-14-extra-regex-redirect-fails` | three strict entries + `^https://evil\.example/.*$`, `regex` | FAIL closed |
| `remediation-15-duplicate-redirect-fails` | three strict entries + duplicate dex callback | FAIL closed |
| `remediation-16-non-strict-matching-mode-fails` | dex callback loosened to `prefix` | FAIL closed |
| `remediation-17-unexpected-redirect-type-fails` | three strict entries + `/device` with type `token` | FAIL closed |
| `remediation-18-normalized-order-and-trailing-slash-passes` | same three entries reordered, callback with a trailing slash | PASS (no false positive) |

Anti-vacuity: `HARNESS_SCRIPT` points the same harness at a pre-fix copy of the validator, so the new
controls are shown to be real detectors rather than always-green assertions.

## S4. Exact commands and observed results

```bash
# environment/branch gate
pwd && (grep -Eiq "microsoft|wsl" /proc/version && echo WSL_OK) && id -un && git branch --show-current
# /mnt/d/SYSADMIN/platforminit-roo-lab
# WSL_OK
# hattila
# batch/platform-ch04-6-oidc-contract-audit        (HEAD 734dcc7)

bash -n platform/identity/validate/ch04-6-validate-argocd-sso.sh
# rc=0   (BASH_N_VALIDATOR_OK)

python3 /tmp/platforminit-evidence/P-CH04.6-T01-py-block-check.py
# PY_BLOCK_COMPILE_OK PYALGS lines=10
# PY_BLOCK_COMPILE_OK PYISSUER lines=11
# PY_BLOCK_COMPILE_OK PYCONTRACT lines=352
# PY_BLOCKS_COMPILE_OK count=3   rc=0

git diff --check
# required validator: rc=0, no output

python3 /tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py
# PASS | control-1-correct-provider                   | rc=0 | PASS=29 WARN=0 FAIL=0
# PASS | control-2-secret-value-never-printed         | client_secret and API-token sentinels absent from validator output
# PASS | negative-3-missing-redirect-uri              | rc=1 | fails closed on a missing CLI callback entry
# PASS | negative-4-missing-ch04-5-group              | rc=1 | fails closed when the CH04.5 group is absent
# PASS | negative-5-duplicate-provider-path           | rc=1 | fails closed on a duplicate provider path
# PASS | negative-6-symmetric-signing-risk            | rc(RS256)=0 rc(HS256)=1 | symmetric-only HS* signing rejected
# PASS | rework-7-error-body-client-secret-not-printed| echoed client_secret and the attributes-bag token never reach the error output while the failure still raises
# PASS | rework-8-error-still-diagnosable             | status code and non-secret field names still reported
# PASS | rework-9-non-json-body-withheld              | non-JSON body summarised by size
# PASS | rework-10-token-echo-under-unexpected-key    | credential under a non-secret key scrubbed by value
# PASS | rework-11-bash-diagnostic-redactor           | removed every sentinel, kept non-secret context
# PASS | remediation-12-extra-wildcard-redirect-fails | FAIL | AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST | ... unexpected extra entries: (url='https://*.evil.example/cb', redirect_uri_type='authorization', matching_mode='strict')
# PASS | remediation-13-extra-prefix-redirect-fails   | FAIL | AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST | ... unexpected extra entries: (url='https://argocd.sysadminhomelab.hu/api', ... matching_mode='prefix'); entries whose matching_mode is not 'strict': (same entry)
# PASS | remediation-14-extra-regex-redirect-fails    | FAIL | AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST | ... unexpected extra entries: (url='^https://evil\\.example/.*$', ... matching_mode='regex'); entries whose matching_mode is not 'strict': (same entry)
# PASS | remediation-15-duplicate-redirect-fails      | FAIL | AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST | ... duplicate entries: (url='https://argocd.sysadminhomelab.hu/api/dex/callback', ... matching_mode='strict')
# PASS | remediation-16-non-strict-matching-mode-fails| FAIL | AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST | ... unexpected extra entries + missing expected entries + entries whose matching_mode is not 'strict': (url='https://argocd.sysadminhomelab.hu/api/dex/callback', ... matching_mode='prefix')
# PASS | remediation-17-unexpected-redirect-type-fails| FAIL | AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST | ... entries with an unexpected redirect_uri_type: (url='https://argocd.sysadminhomelab.hu/device', redirect_uri_type='token', matching_mode='strict')
# PASS | remediation-18-normalized-order-and-trailing-slash-passes | allowlist PASS emitted, exact set accepted
# harness overall: PASS (18 controls)   rc=0

git show 734dcc7:platform/identity/validate/ch04-6-validate-argocd-sso.sh \
  > /tmp/platforminit-evidence/P-CH04.6-T01-prefix-validator.sh
HARNESS_SCRIPT=/tmp/platforminit-evidence/P-CH04.6-T01-prefix-validator.sh \
  python3 /tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py
# FAIL | control-1-correct-provider                  | rc=0 | PASS=28 WARN=0 FAIL=0        <- pre-fix revision has 28 checks, no allowlist assertion
# PASS | control-2-secret-value-never-printed        | ...  (unchanged controls still pass)
# PASS | rework-7..11                              | ...  (reconciler untouched, redaction controls still pass)
# FAIL | remediation-12-extra-wildcard-redirect-fails | no allowlist FAIL emitted        <- SEC-01 reproduced
# FAIL | remediation-13-extra-prefix-redirect-fails  | no allowlist FAIL emitted        <- SEC-01 reproduced
# FAIL | remediation-14-extra-regex-redirect-fails   | no allowlist FAIL emitted        <- SEC-01 reproduced
# FAIL | remediation-15-duplicate-redirect-fails     | no allowlist FAIL emitted        <- SEC-01 reproduced
# FAIL | remediation-16-non-strict-matching-mode-fails | no allowlist FAIL emitted      <- SEC-01 reproduced
# FAIL | remediation-17-unexpected-redirect-type-fails | no allowlist FAIL emitted      <- SEC-01 reproduced
# FAIL | remediation-18-normalized-order-and-trailing-slash-passes | rc=0 fails=0   (positive marker absent pre-fix)
# harness overall: FAIL (18 controls)   rc=1

bash platform/identity/validate/ch04-6-validate-argocd-sso.sh
# FAIL | AUTHENTIK_ROLLOUT | authentik-server rollout is not healthy   rc=1
# (not treated as passing: kubectl is absent in this WSL workspace)
```

Anti-vacuity conclusion: against the pre-fix revision every `SEC-01` fixture is accepted
(`rc=0`, no allowlist line at all) and the new controls fail, so they genuinely detect the missing
completeness assertion; against the fixed revision the same fixtures fail closed while the correct
three-entry set still passes.

Reused unchanged evidence (explicitly **not** re-run):

- `rework-7..11` and the `control-1..6`/`negative-3..6` controls: re-executed in this pass and still
  passing, and the round-2 recorded results for the rework controls remain valid because the
  reconciliation script is byte-identical to the reviewed revision.
- CH04.5 validators: the earlier `41/0/0` and `27/0/0` results are **reused, not re-run** — both
  statically consume only the untouched reconciliation script
  (`grep -n ch04-6 platform/identity/validate/ch04-5-validate-*.sh` → `scripts/ch04-6-enable-argocd-sso.sh`
  at lines 54, 138 and 49); neither reads the validator changed here.

Evidence artifacts (outside the repository, transient):

- `/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py` (extended, 18 controls)
- `/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness-remediation.log`
- `/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness-prefix.log`
- `/tmp/platforminit-evidence/P-CH04.6-T01-prefix-validator.sh` (pre-fix revision `734dcc7`)
- `/tmp/platforminit-evidence/P-CH04.6-T01-py-block-check.py`

## S5. Acceptance criteria after remediation

| Criterion | Status | Evidence |
|---|---|---|
| 1. Provider/application contract explicit and current | MET (unchanged) | Redirect contract now includes completeness; runbook states it; nothing else in the contract moved. |
| 2. Issuer, redirect URI, scopes and secret references validated without exposing secret values | MET | Inclusive checks preserved **plus** the completeness assertion; `control-2` proves no client-secret/API-token sentinel reaches validator output, and the new failure detail renders only contract URLs/modes. |
| 3. Reuses the existing implementation instead of a parallel OIDC path | MET (unchanged) | Same validator, same `PYCONTRACT` block, same invocation contract; no new script, provider path, template or workflow. |

Explicitly out of scope for this batch (unchanged accepted residual risks): `kubectl -p` argv credential
exposure; key-name/prose-dependent bash redaction; legacy `oidc.authentik.clientSecret` warning vs removal;
[`platform/identity/README.md`](../../platform/identity/README.md:78) documentation drift; and the absence of
live evidence because `kubectl` is unavailable in this workspace.

## S6. Residual risk handed to the reviewers

1. **Live evidence still does not exist.** All remediation evidence is offline/static; the live validator
   reports `FAIL | AUTHENTIK_ROLLOUT` (no `kubectl`). The next approved `04.6 - Enable Argo CD SSO` run
   remains the only live proof that the real provider carries exactly the three strict entries.
2. **Field-absence behaviour is unchanged.** If a deployed Authentik API version does not serialize
   `redirect_uris`, the empty collection still fails the per-URI checks (and now also the completeness
   check) rather than warning; this preserves the previous fail-closed stance but is worth reviewer
   confirmation against the deployed API version.
3. **Malformed entries fail closed.** A non-dict `redirect_uris` element now fails the completeness check
   instead of being skipped by the entry matcher.
4. `docs/reviews/**` remains the mandated evidence exception outside the controller `allowedFiles`.

## S7. Controller transition

This remediation child records exactly one transition and routes nothing onward:

```text
python3 tools/task_controller/taskctl.py submit P-CH04.6-T01 --actor platforminit-deepseek-coder
```

---

# Round-3 reviewer verdict (`platforminit-openai-reviewer`)

- **Review scope:** remediation diff `734dcc7..HEAD`; three requested paths were checked. The diff contains only [`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:1) and [`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:1); [`ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1) is byte-identical to `734dcc7`.
- **Verdict:** **REQUEST_CHANGES**

## Consolidated finding

### P1 — Redirect URI normalization is incomplete and can produce false failures

The new tuple comparison at [`normalize_redirect_url()`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:444) removes trailing slashes only. It does not normalize the case-insensitive URL components (at minimum the scheme and authority/host), while the expected values are constructed in lowercase at [`expected_redirect_targets`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:438). Consequently, a semantically equivalent live entry such as `HTTPS://ARGOCD.<domain>/api/dex/callback` or a host-cased equivalent is represented as an extra tuple and the lowercase expected tuple is represented as missing. The completeness assertion at [`line 506`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:506) then fails despite the provider carrying the same three redirect targets. This contradicts the round-3 requirement that normalization avoid false failures.

Fix the normalizer to canonicalize only URL semantics that are case-insensitive (scheme and hostname, while preserving case-sensitive path/query/fragment semantics), then add a focused positive harness control covering equivalent scheme/host casing. Do not lowercase the complete URL, because redirect paths remain case-sensitive.

## SEC-01 assessment

The remediation closes the original inclusive-only gap for the tested contract: the full live collection is converted to `(url, redirect_uri_type, matching_mode)` tuples; extra wildcard/prefix/regex entries, duplicates, non-strict modes, unexpected types, malformed entries, and missing entries fail closed. Ordering is harmless, and trailing-slash normalization is consistent with the existing matcher. The duplicate check is separate from set subtraction, so duplicate collapsing cannot hide an exact duplicate.

SEC-01 is therefore **not fully closed for approval** until the case-normalization false-positive is fixed and tested. The failure detail itself is credential-safe for the reviewed contract: it renders only redirect URL/type/mode tuples and no client secret, API token, or secret reference value. The absent/empty `redirect_uris` behavior is intentionally fail-closed: the three per-entry checks and completeness assertion fail rather than downgrade the contract to a warning when an API response omits the field. That behavior is documented in the existing round-3 residual-risk text and is acceptable.

## Acceptance criteria

1. **Provider/application contract explicit and current:** met for the reviewed changes; the runbook and validator state the exact three-entry strict allow-list and preserve the existing provider/application linkage.
2. **Issuer, redirect URI, scopes and secret references validated without exposing secret values:** not yet approvable because the redirect validator can falsely reject semantically equivalent URL casing. Secret safety and the round-1 error-path redaction remain intact.
3. **Reuse of existing implementation:** met; no parallel OIDC path, script, workflow, or template was introduced.

## Evidence independently run

- WSL, repository, branch, and remote gate passed; current branch is `batch/platform-ch04-6-oidc-contract-audit`.
- `git diff --check 734dcc7..HEAD -- <three paths>`: rc 0.
- `bash -n platform/identity/validate/ch04-6-validate-argocd-sso.sh`: rc 0.
- `python3 /tmp/platforminit-evidence/P-CH04.6-T01-py-block-check.py`: `PY_BLOCKS_COMPILE_OK count=3`, rc 0; the three blocks were `PYALGS`, `PYISSUER`, and `PYCONTRACT` (`352` lines).
- `python3 /tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py`: all 18 controls passed, overall rc 0, including controls 12–17 for extra/duplicate/non-strict/unexpected entries and control 18 for reordered entries plus trailing slash.
- Anti-vacuity with `HARNESS_SCRIPT=/tmp/platforminit-evidence/P-CH04.6-T01-prefix-validator.sh`: overall rc 1 as required; controls 12–17 reported `no allowlist FAIL emitted` against `734dcc7`.
- Round-1 P1 fix verified intact: the reconciler is byte-identical to `734dcc7`; its [`request()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:366) sanitized error path and [`redact_secret_fields()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:64) diagnostic sinks remain present.
- CH04.5 validator evidence is reused, not rerun: path-scoped inspection confirms both validators statically read only the unchanged CH04.6 reconciler, not the changed validator.
- Live validation remains unavailable and was not treated as a pass: the expected `AUTHENTIK_ROLLOUT` failure occurs because `kubectl` is unavailable in this WSL workspace.

## Residual-risk classification

- **Blocker for approval:** incomplete URL normalization at [`normalize_redirect_url()`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:444), as detailed above.
- **Accepted follow-up, not a new blocker:** no live runtime evidence; only an approved `04.6` workflow run proves the deployed provider's exact three strict entries.
- **Accepted intentional behavior:** absent/empty or unserialized `redirect_uris` fails closed rather than warns; this is safer for the redirect allow-list and is documented.
- **Accepted security-review follow-ups, not re-raised:** [`kubectl -p`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1) argv exposure, key-name/prose-dependent bash redaction, legacy `oidc.authentik.clientSecret` warning-versus-removal, and [`platform/identity/README.md`](../../platform/identity/README.md:78) drift. The round-1 security acceptance remains unchanged.
- **Evidence-path exception:** [`docs/reviews/**`](P-CH04.6-T01.md:1) and [`docs/security-reviews/**`](../security-reviews/P-CH04.6-T01.md:1) remain mandated evidence paths outside controller `allowedFiles`.

## Required controller transition

```bash
python3 tools/task_controller/taskctl.py review P-CH04.6-T01 --actor platforminit-openai-reviewer --verdict request_changes --report docs/reviews/P-CH04.6-T01.md
```

---

# Round-4 remediation (`platforminit-deepseek-coder`)

Round-4 implements the single consolidated defect from the round-3 verdict above and changes nothing
else. The round-3 reviewer verdict was committed as-is; no reviewer text was rewritten or deleted.

## R1. Defect (restated precisely)

The round-3 normalizer at `normalize_redirect_url()` applied `str(url or "").rstrip("/")` only. Because
the expected targets are built in lowercase at
[`expected_redirect_targets`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:468), a live
provider entry written as `HTTPS://ARGOCD.<domain>/api/dex/callback` — or any equivalent differing only
in scheme/host casing — canonicalized to itself instead of to the lowercase contract value. The
completeness comparison at
[`AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:558)
then reported the same three targets simultaneously as `unexpected extra entries` and
`missing expected entries`, so a provider carrying exactly the correct three strict targets failed.

## R2. Fix — one canonical normalizer for every URL comparison

A single module-level helper now owns URL normalization:

- [`canonical_url()`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:316) strips the
  trailing slash (unchanged behaviour) and then canonicalizes only the case-insensitive URL semantics
  through `urllib.parse.urlsplit`/`urlunsplit`: `scheme` and `netloc` (host/authority) are lowercased,
  while `path`, `query` and `fragment` are re-emitted byte-exact, so redirect paths stay
  case-sensitive. A value without scheme and netloc (relative, placeholder, or a regex-shaped entry such
  as `^https://evil\.example/.*$`) is returned unchanged, so extra-entry detection and the
  credential-free failure rendering are unaffected.
- Every URL comparison in the block consumes that one helper, so no path can disagree about casing and
  none can be bypassed by casing:
  [`same_url()`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:343) (the `logout_uri`
  field check), [`redirect_tuple()`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:478)
  (each live entry), [`expected_redirect_tuples`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:499)
  (expected side of the completeness comparison) and
  [`strict_entry_registered()`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:505) (the
  per-URI matcher). The nested `normalize_redirect_url()` shim was removed rather than duplicated, so the
  validator now contains exactly one normalization implementation.
- Unchanged: the `PASS | CODE | detail` output format, the fail-fast `exit 1`, the single `PYCONTRACT`
  parsing path, the completeness assertion itself (extra / duplicate / non-strict / unexpected-type
  entries), the round-1 error-path redaction, and the validator invocation contract.
- The file header documents the normalization semantics for the operator reading the validator.

Deliberately not implemented by lowercasing the whole URL: a path-cased difference must still fail
closed, which control 20 asserts.

## R3. New harness controls (same offline evidence channel)

The harness at `/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py` (transient, outside the
repository) was extended, not replaced: controls 1-6, `rework-7..11` and `remediation-12..18` are
unchanged, and two controls were added.

| Control | Fixture | Expected |
|---|---|---|
| `remediation-19-scheme-and-host-case-variant-passes` | the same three contract entries, reordered, with scheme+host uppercased (`HTTPS://ARGOCD.SYSADMINHOMELAB.HU/api/dex/callback`, `HTTPS://LOCALHOST:8085/auth/callback`, `HTTPS://ARGOCD.SYSADMINHOMELAB.HU/logout`), paths untouched | PASS: allowlist `PASS` emitted, no extra/missing tuple |
| `remediation-20-path-case-difference-still-fails` | dex callback path written `/API/dex/callback` | FAIL closed with both `unexpected extra entries` and `missing expected entries` |

## R4. Exact commands and observed results

```bash
# environment/branch gate
pwd && (grep -Eiq "microsoft|wsl" /proc/version && echo WSL_OK) && id -un && git branch --show-current
# /mnt/d/SYSADMIN/platforminit-roo-lab
# WSL_OK
# hattila
# batch/platform-ch04-6-oidc-contract-audit        (HEAD ab3565d)

bash -n platform/identity/validate/ch04-6-validate-argocd-sso.sh
# BASH_N_VALIDATOR_OK   rc=0

python3 /tmp/platforminit-evidence/P-CH04.6-T01-py-block-check.py
# PY_BLOCK_COMPILE_OK PYALGS lines=10
# PY_BLOCK_COMPILE_OK PYISSUER lines=11
# PY_BLOCK_COMPILE_OK PYCONTRACT lines=378
# PY_BLOCKS_COMPILE_OK count=3   rc=0

git diff --check
# required validator: rc=0, no output

python3 /tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py
# PASS | control-1-correct-provider                       | rc=0 | PASS=29 WARN=0 FAIL=0
# PASS | control-2-secret-value-never-printed             | ... (unchanged)
# PASS | negative-3..6 / rework-7..11 / remediation-12..18 | ... (unchanged, still passing)
# PASS | remediation-19-scheme-and-host-case-variant-passes | scheme/host-upper-cased three-entry set accepted as equivalent
# PASS | remediation-20-path-case-difference-still-fails | FAIL | AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST | ... unexpected extra entries: (url='https://argocd.sysadminhomelab.hu/API/dex/callback', redirect_uri_type='authorization', matching_mode='strict'); missing expected entries: (url='https://argocd.sysadminhomelab.hu/api/dex/callback', ...) | path case difference rejected (extra + missing reported)
# harness overall: PASS (20 controls)   rc=0

# anti-vacuity: the new positive control must fail against the pre-fix validator
git show ab3565d:platform/identity/validate/ch04-6-validate-argocd-sso.sh \
  > /tmp/platforminit-evidence/P-CH04.6-T01-round3-prefix-validator.sh
HARNESS_SCRIPT=/tmp/platforminit-evidence/P-CH04.6-T01-round3-prefix-validator.sh \
  python3 /tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py
# FAIL | remediation-19-scheme-and-host-case-variant-passes | rc=1 fails=4    <- P1 reproduced (3 per-URI checks + allowlist fail on casing)
# PASS | remediation-20-path-case-difference-still-fails | ... path case difference rejected
# harness overall: FAIL (20 controls)   rc=1

bash platform/identity/validate/ch04-6-validate-argocd-sso.sh
# FAIL | AUTHENTIK_ROLLOUT | authentik-server rollout is not healthy   rc=1
# (not treated as passing: kubectl is absent in this WSL workspace)
```

Anti-vacuity: `remediation-19` fails against the `ab3565d` validator copy (`rc=1`, four failures — the
three per-URI checks plus the completeness assertion), so the control genuinely detects the casing
defect; the same control passes against the fixed validator. `remediation-20` passes on both revisions,
confirming the fix canonicalizes scheme/host without collapsing path case.

Reused unchanged evidence (explicitly **not** re-run):

- CH04.5 validators: the recorded `41/0/0` (identity-model-contract) and `27/0/0` (cross-consumer)
  results remain valid because this round changes no input they consume. `grep -n ch04-6` shows both
  statically read only `platform/identity/scripts/ch04-6-enable-argocd-sso.sh` (lines 54/138 and 49),
  which is byte-identical to `ab3565d` (sha256
  `270c761f77daa0b5355d587a1667f1a30143e060acab7cbccb2f0c0822fd8945`); no CH04.5 validator references
  the changed validator.
- The `rework-7..11` redaction controls were re-executed in this pass and still pass; the reconciler is
  untouched.

Evidence artifacts (outside the repository, transient):

- `/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py` (extended, 20 controls)
- `/tmp/platforminit-evidence/P-CH04.6-T01-round4-harness.log`
- `/tmp/platforminit-evidence/P-CH04.6-T01-round4-harness-prefix.log`
- `/tmp/platforminit-evidence/P-CH04.6-T01-round3-prefix-validator.sh` (pre-fix `ab3565d`)
- `/tmp/platforminit-evidence/P-CH04.6-T01-round4-py-block-check.log`
- `/tmp/platforminit-evidence/P-CH04.6-T01-round4-live.log`

## R5. Acceptance criteria after the round-4 remediation

| Criterion | Status | Evidence |
|---|---|---|
| 1. Provider/application contract explicit and current | MET (unchanged) | The three strict entries are asserted per-URI and as a complete collection; normalization semantics are now documented in the file header. |
| 2. Issuer, redirect URI, scopes and secret references validated without exposing secret values | MET | Case-insensitive scheme/host and case-sensitive path behaviour asserted by controls 19/20; `control-2` still proves no client-secret/API-token sentinel reaches output; failure details render contract URLs/types/modes only. |
| 3. Reuses the existing implementation instead of a parallel OIDC path | MET (unchanged) | Same validator, same `PYCONTRACT` block, same invocation contract; no new script, provider path, template or workflow. |

## R6. Residual risk handed to the reviewers

1. **Live evidence still does not exist.** All round-4 evidence is offline/static; the live validator
   reports `FAIL | AUTHENTIK_ROLLOUT` because `kubectl` is absent. Only an approved
   `04.6 - Enable Argo CD SSO` run proves the deployed provider carries exactly the three strict entries.
2. **`same_url()` semantics widened for `logout_uri`.** The `logout_uri` field check now also accepts a
   case-variant scheme/host on that one value. This applies the same RFC 3986 rule the redirect matcher
   uses and removes the previous inconsistency where the allow-list accepted such an entry while the
   `logout_uri` check rejected it; a differently cased *path* still fails. Reviewers should confirm they
   accept this as part of the same fix rather than as a behaviour expansion.
3. **Unchanged accepted risks:** `matching_mode` and `redirect_uri_type` remain compared
   case-sensitively (fail-closed); an absent or empty `redirect_uris` collection still fails closed
   rather than warns; the `kubectl -p` argv exposure, the key-name/prose-dependent bash redaction, the
   legacy `oidc.authentik.clientSecret` warn-vs-remove choice and the
   [`platform/identity/README.md`](../../platform/identity/README.md:78) drift remain accepted
   follow-ups.
4. `docs/reviews/**` remains the mandated evidence exception outside the controller `allowedFiles`.

## R7. Controller transition

This remediation child records exactly one transition and routes nothing onward:

```text
python3 tools/task_controller/taskctl.py submit P-CH04.6-T01 --actor platforminit-deepseek-coder
```
