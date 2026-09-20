# Implementation and validation evidence: P-CH04.6-T01

Audit the existing Authentik OIDC provider contract for Argo CD.

## Scope and lifecycle

- Task: `P-CH04.6-T01`, track `platform`, stage `implementation`.
- Branch: `batch/platform-ch04-6-oidc-contract-audit` (checked out from fresh `dev` @ `8371154`).
- Allowed-file scope: `platform/identity/scripts/ch04-6-enable-argocd-sso.sh`,
  `platform/identity/integrations/argocd/**`,
  `platform/identity/docs/ch04-6-argocd-sso-runbook.md`,
  `platform/identity/validate/ch04-6-validate-argocd-sso.sh`, `tasks/**`.
- Changed non-state files (3 of 4; target was 1-3):
  - [`platform/identity/scripts/ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1)
  - [`platform/identity/validate/ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:1)
  - [`platform/identity/docs/ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:1)
- Not changed: `platform/identity/integrations/argocd/**`. The two provider templates
  already carry the contract correctly (closed four-placeholder inventory, no inlined
  secret, `$dex.authentik.clientSecret` reference), so touching them would have been a
  needless contract change under the CH04.5 template rules.
- The uncommitted controller state from `taskctl start`
  (`tasks/tracker.json`, `tasks/active/NEXT_TASK.md`,
  `tasks/active/platform/NEXT_TASK.md`) is preserved unchanged and committed as-is.
- No infrastructure workflow was run. No Authentik, Kubernetes, DNS, Cloudflare, GitHub
  secret or GitHub environment was mutated. No secret value was read, printed or
  committed.

## 1. What was audited (reference state, not greenfield)

The existing CH04.6 implementation was read as reference-state and checked against the
CH04.5 identity model that `P-CH04.5-T05` closed and merged on `dev`:

- [`ch04-5-identity-model-contract.md`](../../platform/identity/docs/ch04-5-identity-model-contract.md:190)
  section 6 states that CH04.5 owns the group taxonomy and that the CH04.6 SSO binding
  "must not create, rename or delete CH04.5 groups", and records an advisory that the
  CH04.6 group payload sends `attributes: {}` and clears CH04.5 ownership stamps.
- [`deploy-04-5-identity-foundation.yml`](../../.github/workflows/deploy-04-5-identity-foundation.yml:273)
  runs `ch04-5-bootstrap-identity-model.sh`, which creates the taxonomy groups, so the
  admin group already exists before CH04.6 runs.
- [`deploy-04-6-argocd-sso.yml`](../../.github/workflows/deploy-04-6-argocd-sso.yml:219)
  renders the SSO script and then runs
  [`ch04-6-validate-argocd-sso.sh`](../../.github/workflows/deploy-04-6-argocd-sso.yml:227)
  on the host, so the validator's path, environment and exit-code contract had to stay
  stable.
- The CH04.5 repository-only validators statically inspect the CH04.6 script
  (`ARGOCD_ADMIN_GROUP` default declaration, the four template `sed` substitutions), so
  those anchors were preserved deliberately.

### Drift found

| # | Drift | Consequence |
|---|---|---|
| 1 | The validator derived the expected issuer from a hardcoded `https://auth.<BASE_DOMAIN>` host, while the script derived it from `AUTHENTIK_BASE_URL`. | A non-default `AUTHENTIK_BASE_URL` produced a false validator failure. |
| 2 | The script created the group (`POST /api/v3/core/groups/`) and PATCHed it with `attributes: {}` and `is_superuser`/`parent`. | CH04.6 wrote a CH04.5-owned object, restating the identity model and able to clear CH04.5 ownership stamps. |
| 3 | The script patched the unused direct-OIDC key `oidc.authentik.clientSecret` into `argocd-secret` while removing `oidc.config`. | A second, inert client-secret path contradicted "one Dex-backed path only". |
| 4 | Connector scopes and provider scope mappings were two independent literals, and the validator asserted only the `groups` scope. | Scope drift between the request and the provider mapping was undetectable. |
| 5 | The validator never asserted the provider/application contract at all: no redirect URI, no provider identity, no scope mappings, no provider/application link. | Acceptance gap 1 and the redirect/scope half of acceptance gap 2 had no live evidence. |

## 2. What was hardened

### Script: [`ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1)

- Contract header plus single-source contract constants
  ([`ARGOCD_OIDC_SCOPES`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:68),
  [`AUTHENTIK_OIDC_EXPECTED_ISSUER`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:73)),
  documenting which objects CH04.6 owns, which CH04.5 owns and which keys exist.
- [`require_authentik_admin_group()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:333)
  replaces the group writer: exact-name lookup only, no `POST`/`PATCH` on
  `/api/v3/core/groups/`, no group attributes written, and a fail-closed error naming the
  CH04.5 remedy when the group is missing, is a superuser group or inherits a parent.
  Only the admin identity's membership is still converged, which keeps the documented
  `authentik_argocd_admin_username` input working and idempotent.
- [`resolve_or_create_argocd_oidc_secret()`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:194)
  now writes exactly one key (`dex.authentik.clientSecret`) and removes the legacy
  `oidc.authentik.clientSecret` key when an earlier direct-OIDC configuration left it
  behind (presence-guarded, field-scoped JSON patch, idempotent).
- The discovery validation asserts the advertised `issuer` equals the derived contract
  issuer, and the connector scope list is generated from the same scope constant
  ([`scopes_block`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:678)), so
  the requested scopes and the provider mappings cannot drift apart.
- Redirect URI entries are now named contract values: browser Dex callback, Argo CD CLI
  callback, logout, all `matching_mode: strict`.

### Validator: [`ch04-6-validate-argocd-sso.sh`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:1)

Still the single focused validator for this scope; same path, same environment, same
`PASS | CODE | detail` lines, same fail-fast non-zero exit. It now asserts, read-only:

- `argocd-cm` `data.url`, the Dex connector contract (issuer derived from
  `AUTHENTIK_BASE_URL` at
  [`EXPECTED_ISSUER`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:54),
  client ID match, the `$dex.authentik.clientSecret` reference, `insecureEnableGroups`)
  and all four scopes at
  [`for scope in ${EXPECTED_SCOPES}`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:117)).
- The discovery issuer (`AUTHENTIK_OIDC_ISSUER_MATCH`) alongside the existing signing
  algorithm check, so a symmetric-only or drifting issuer fails closed.
- Secret-reference ownership: the `argocd-authentik-oidc` secret, the
  `dex.authentik.clientSecret` key, the `server.secretkey` key, and the absence of the
  legacy direct-OIDC key
  ([`ARGOCD_LEGACY_OIDC_SECRET_ABSENT`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:143)).
  Only key presence and the non-secret client ID are read; the provider client secret is
  probed for presence only and never printed.
- The Authentik provider contract
  ([`PYCONTRACT`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:222)):
  exactly one provider
  ([`AUTHENTIK_PROVIDER_UNIQUE`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:359)),
  `client_type confidential`, `authorization_code` grant, `sub_mode hashed_user_id`,
  `issuer_mode per_provider`, ID-token claims, an asymmetric `signing_key`, the strict
  redirect allow-list (browser, CLI, logout), and every scope mapping.
- The application contract: exactly one application for the slug and the
  provider link
  ([`AUTHENTIK_APPLICATION_PROVIDER_LINK`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:485)),
  which is the "no parallel OIDC path" proof.
- The CH04.5 consumption rule
  ([`AUTHENTIK_ADMIN_GROUP_EXISTS`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:316)):
  the group must exist, be non-superuser, have no parent, and the admin identity must be
  a direct member. Missing ownership stamps are a `WARN` (the CH04.5 reconciler re-stamps
  them), not a blocking failure.
- Fields an Authentik version may not serialize (`client_type`, `sub_mode`,
  `issuer_mode`, `include_claims_in_id_token`, `logout_uri`, `logout_method`,
  `grant_types`, `client_secret`) use
  [`expect_field()`](../../platform/identity/validate/ch04-6-validate-argocd-sso.sh:260):
  `WARN` when the API does not expose the field, `FAIL` when it exposes a wrong value.
  This makes the extended validator safe to enable on an existing host.

### Runbook: [`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:1)

Added the explicit contract: provider/application table, issuer derivation rule, secret
reference ownership table with key names, the CH04.5 consumption rule with the ordering
prerequisite, the stable validator invocation plus repository-only companions, and a
drift-reconciliation section recording the five findings above and the residual notes.

## 3. Exact commands run and observed results

```bash
bash -n platform/identity/scripts/ch04-6-enable-argocd-sso.sh
# BASH_SYNTAX_OK

python3 -  # extract each <<'TAG' heredoc and compile() it
# OK PY:13 lines / OK PY:330 lines / OK PY:46 lines / OK PYCODE:23 lines / OK PYCODE:3 lines

grep -n 'ensure_authentik_group\|"attributes": {}' platform/identity/scripts/ch04-6-enable-argocd-sso.sh
# no match: the group writer and the attributes-clearing payload are gone

bash platform/identity/validate/ch04-5-validate-identity-model-contract.sh
# pass=41 warn=0 fail=0, rc=0
#   The previous "CH04.6_GROUP_PAYLOAD_ADVISORY" WARN is resolved; warn is now 0 and
#   CONSUMER_ARGOCD_ADMIN_GROUP still PASSes for the default 'PlatformInit Admins'.

bash platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh
# pass=27 warn=0 fail=0, rc=0

bash -n platform/identity/validate/ch04-6-validate-argocd-sso.sh
# BASH_SYNTAX_OK

python3 -  # compile the PYCONTRACT heredoc
# OK PYCONTRACT: 270 lines

python3 /tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py
# PASS | control-1-correct-provider          | rc=0 | PASS=28 WARN=0 FAIL=0
# PASS | control-2-secret-value-never-printed| rc=0 | client_secret sentinel absent from output
# PASS | negative-3-missing-redirect-uri     | rc=1 | fails closed
# PASS | negative-4-missing-ch04-5-group     | rc=1 | fails closed
# PASS | negative-5-duplicate-provider-path  | rc=1 | fails closed
# PASS | negative-6-symmetric-signing-risk   | rc=1 | fails closed
# harness overall: PASS (6 controls)

bash platform/identity/validate/ch04-6-validate-argocd-sso.sh
# FAIL | AUTHENTIK_ROLLOUT | authentik-server rollout is not healthy
# validator_rc=1

git diff --check
# required validator: rc=0, no output
```

### Why the live validator cannot pass in this environment

`kubectl` is absent from this WSL workspace (`command -v kubectl` -> absent; there is no
cluster and no `/etc/rancher/k3s/k3s.yaml`), and the task forbids running infrastructure
workflows. The validator is therefore **not** claimed as passed: it executed, failed
closed at its first check and returned `1`. The exact command and the exact result are
recorded above. The provider/application contract logic of that same validator is
exercised instead by the offline harness, which extracts the embedded `PYCONTRACT` block,
stubs the read-only Authentik GET surface and drives six positive/negative controls.

Evidence artifacts (outside the repository, transient):

- `/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.py`
- `/tmp/platforminit-evidence/P-CH04.6-T01-contract-harness.log`

## 4. Acceptance criteria

| Criterion | Status | Evidence |
|---|---|---|
| 1. The existing Authentik provider/application contract for Argo CD is explicit and current | MET | Contract constants in the script, the provider/application tables in [`ch04-6-argocd-sso-runbook.md`](../../platform/identity/docs/ch04-6-argocd-sso-runbook.md:20), and live assertions in the validator. |
| 2. Issuer, redirect URI, scopes and secret references are validated without exposing secret values | MET | Issuer derived once and asserted twice; strict redirect allow-list; all four scopes plus mappings; secret keys asserted as presence only; harness control 2 proves no secret value is printed. |
| 3. The task reuses the existing implementation instead of recreating a parallel OIDC path | MET | No new script, validator, runbook, template or provider path. The same script and validator were hardened; `AUTHENTIK_PROVIDER_UNIQUE`, `AUTHENTIK_APPLICATION_UNIQUE` and the provider link assertion prove single-path topology. The group is now consumed from CH04.5 rather than restated. |

## 5. Unresolved risks and what a reviewer must check

1. **Runtime evidence is missing by construction.** The live validator was not executed
   against `platforminit-dev-01`. A reviewer or the orchestrator must not treat the
   offline harness as live evidence; the next `04.6 - Enable Argo CD SSO` run produces the
   real verdict at
   `<PLATFORMINIT_IDENTITY_PATH>/platforminit/reports/ch04-6-argocd-sso-validate-<SHORT_SHA>.log`.
2. **Behavioural change on a host without the CH04.5 group.** CH04.6 now fails closed
   instead of creating `PlatformInit Admins`. Ordering (`04.5` before `04.6`) is
   documented and matches the existing `authentik-bootstrap` secret prerequisite, but a
   host that never ran the CH04.5 model bootstrap will now stop with a CH04.5 pointer.
3. **`docs/reviews` evidence file is outside the controller `allowedFiles`.** It was
   produced because the task explicitly required this evidence path; a reviewer should
   confirm that this matches the orchestrator's expectation.
4. **Stale pointer outside the allowed scope:**
   [`platform/identity/README.md`](../../platform/identity/README.md:86) still states that
   the workflow patches `oidc.authentik.clientSecret`. That file was not in scope and the
   statement is now inaccurate; it needs a follow-up documentation fix.
5. **Provider/application reconciliation is convergent but not write-free.** The
   provider and application `PATCH` runs unconditionally, so a re-run produces no drift
   but is not a no-op. Adding an `UNCHANGED` short-circuit is a follow-up, deliberately not
   done here to keep this audit patch bounded.
6. **Provider field availability is version-dependent.** The new provider assertions
   `WARN` when an Authentik version does not serialize a field, so the reviewer should
   confirm on the next live run whether any `WARN | AUTHENTIK_PROVIDER_*` line appears; a
   consistently missing field would mean the contract is only enforced on the write path.
7. **`is_superuser`/parent checks assume the API field names** the CH04.5 validator
   already uses. If an Authentik version renames them, the object is reported as absent
   fields rather than failing loudly.

## 6. Controller transition

This implementation stage records exactly one transition and routes nothing onward:

```text
python3 tools/task_controller/taskctl.py submit P-CH04.6-T01 --actor platforminit-deepseek-coder
```

The next mode returned by the controller is `platforminit-deepseek-coder` as a fresh
review-bound child; the orchestrator owns all next-stage routing. No branch was switched,
no `git push` was performed, and no controller state was edited by hand.
