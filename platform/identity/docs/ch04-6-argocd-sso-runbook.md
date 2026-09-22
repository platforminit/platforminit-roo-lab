# CH04.6 - Argo CD SSO Runbook

## Goal

Enable Argo CD login through Authentik while keeping the local Argo CD admin account as a break-glass path.

CH04.6 uses Argo CD's bundled Dex server as the Authentik OIDC broker. This matches the Authentik Argo CD integration model and avoids the direct `oidc.config` callback/token-verification path that previously produced browser-side `failed to verify the token` errors.

## Authentik application/provider bootstrap

The workflow reconciles the Argo CD OAuth2/OIDC provider and application in Authentik through the Authentik API. Do not create GitHub secrets for the Argo CD client ID or client secret.

Task `P-CH04.6-T01` audited this surface and made the provider/application
contract, the issuer derivation, the redirect URI allow-list, the scope set and
the secret-reference ownership explicit. This section is the contract; the
reconciliation script [`ch04-6-enable-argocd-sso.sh`](../scripts/ch04-6-enable-argocd-sso.sh:1)
writes it, and the validator [`ch04-6-validate-argocd-sso.sh`](../validate/ch04-6-validate-argocd-sso.sh:1)
asserts it against the live objects read-only, without printing a secret value.

### Provider and application contract

| Field | Contract value | Owner |
|---|---|---|
| Provider type | `OAuth2/OpenID Connect`, `client_type: confidential` | CH04.6 |
| Provider name | `Argo CD`; exactly one provider may carry this name | CH04.6 |
| Application name | `Argo CD` | CH04.6 |
| Application slug | `argocd` by default (`argocd_provider_slug` workflow input) | CH04.6 |
| Application -> provider link | the one asserted provider primary key, so no parallel OIDC path exists | CH04.6 |
| Grant types | `authorization_code`, `refresh_token` | CH04.6 |
| `sub_mode` | `hashed_user_id` | CH04.6 |
| `issuer_mode` | `per_provider` | CH04.6 |
| ID token claims | `include_claims_in_id_token: true`, so the `groups` claim reaches Argo CD RBAC | CH04.6 |
| Signing key | an explicit Authentik certificate/key pair; symmetric-only HS* signing is rejected | CH04.6 |
| Browser redirect URI | `https://argocd.<PLATFORM_BASE_DOMAIN>/api/dex/callback`, `matching_mode: strict`, type `authorization` | CH04.6 |
| CLI callback URI | `https://localhost:8085/auth/callback`, `matching_mode: strict`, type `authorization` | CH04.6 |
| Logout redirect URI | `https://argocd.<PLATFORM_BASE_DOMAIN>/logout`, `matching_mode: strict`, type `logout` | CH04.6 |
| Logout URI / method | `https://argocd.<PLATFORM_BASE_DOMAIN>/logout` / `frontchannel` | CH04.6 |
| Scopes | `openid`, `profile`, `email`, `groups`, each backed by an Authentik scope mapping; the `groups` mapping (`PlatformInit Argo CD Groups`) emits Authentik group names into the ID token | CH04.6 |

The redirect URI allow-list is strict: no wildcard, prefix or regex matching.
Adding, removing or loosening a redirect URI is a contract change, not a routine
reconciliation.

The validator asserts that allow-list for completeness, not only for inclusion:
the live provider `redirect_uris` collection must contain exactly the three
entries above with `matching_mode: strict`. An extra entry such as a wildcard,
prefix or regex redirect, a duplicate, a non-strict matching mode or an
unexpected `redirect_uri_type` fails the validation run even when the
reconciliation writer did not produce the list last.

### Issuer derivation

The issuer is never hardcoded. The reconciliation resolves `AUTHENTIK_BASE_URL`
(default `https://auth.<PLATFORM_BASE_DOMAIN>`), derives the expected issuer as
`<AUTHENTIK_BASE_URL>/application/o/<provider slug>/`, fetches
`<issuer>/.well-known/openid-configuration` and fails closed when the advertised
`issuer` differs from that expected value. The discovered issuer is the value
written into `argocd-cm` `dex.config`, and the validator asserts both the
discovery issuer and the rendered connector issuer against the same derived
value.

### Secret reference ownership

| Value | Owner | Storage (key names only) |
|---|---|---|
| Argo CD OAuth client ID | CH04.6 automation | `argocd/argocd-authentik-oidc` key `ARGOCD_OIDC_CLIENT_ID` (non-secret identifier) |
| Argo CD OAuth client secret | CH04.6 automation | `argocd/argocd-authentik-oidc` key `ARGOCD_OIDC_CLIENT_SECRET` |
| Dex client secret reference | CH04.6 automation | `argocd/argocd-secret` key `dex.authentik.clientSecret`, referenced from `dex.config` as `$dex.authentik.clientSecret` |
| Argo CD session signing key | CH04 / CH04.6 automation | `argocd/argocd-secret` key `server.secretkey` |
| Authentik API token | CH04.5 identity foundation | `identity/authentik-bootstrap` key `AUTHENTIK_BOOTSTRAP_TOKEN` |

Rules:

1. No secret value is read, printed, committed or copied into a report. The
   validator asserts key presence and non-secret identifiers only.
2. Exactly one OIDC client secret reference exists. CH04.6 removes the legacy
   direct-OIDC key `oidc.authentik.clientSecret` from `argocd-secret` when an
   earlier direct-OIDC configuration left it behind, because the Dex-backed path
   is the only supported path.
3. A client ID or client secret supplied through the environment is written into
   the `argocd-authentik-oidc` secret; when none is supplied, CH04.6 generates the
   credential and stores it there. That secret is the single source of truth for
   the Argo CD OAuth client credential.
4. Failure output is credential-safe by construction. When the Authentik API
   rejects a request, the reconciliation reports the HTTP status code and the
   response field names, and every value whose key names a credential
   (`client_secret`, `clientSecret`, `secret`, token/authorization fields,
   `attributes`, API/private key keys) is replaced by `<redacted>` before the
   error reaches stdout/stderr or the workflow log. The same filter is applied to
   the `dex.config` summary, to `kubectl` response bodies that are echoed and to
   the `argocd-server` log tails collected on a failed rollout. A response that
   echoes the submitted provider payload therefore cannot print the client
   secret, and the values CH04.6 holds are additionally scrubbed from any
   rendered string so a credential repeated under an unexpected key still cannot
   be printed. Operator-visible consequence: an error line shows which field
   failed, not its value, and the remainder of a log line that carries a
   credential key is withheld with it.

## Argo CD Dex connector

CH04.6 writes `dex.config` into `argocd-cm` and removes any previous direct `oidc.config`:

```yaml
dex.config: |
  connectors:
    - type: oidc
      id: authentik
      name: Authentik
      config:
        issuer: https://auth.<PLATFORM_BASE_DOMAIN>/application/o/argocd/
        clientID: platforminit-argocd
        clientSecret: $dex.authentik.clientSecret
        insecureEnableGroups: true
        getUserInfo: true
        scopes:
          - openid
          - profile
          - email
          - groups
```

## Argo CD RBAC model

Default mapping:

```text
g, PlatformInit Admins, role:admin
```

The workflow input `argocd_admin_group` controls the group name. Keep this group small and use local `admin` only for break-glass recovery.

### The admin group is consumed from CH04.5, not redefined

`argocd_admin_group` must name an existing CH04.5 identity-model group. CH04.5
owns the group taxonomy, and its reconciler
[`ch04-5-bootstrap-identity-model.sh`](../scripts/ch04-5-bootstrap-identity-model.sh:1)
is the only writer of groups, memberships and the managed ownership attributes
(see [`ch04-5-identity-model-contract.md`](ch04-5-identity-model-contract.md:1),
section 6).

CH04.6 therefore:

- resolves the group by **exact-name lookup only**;
- never creates, renames, patches or deletes the group, and never writes group
  attributes, so a CH04.6 run cannot clear CH04.5 ownership stamps;
- fails closed, naming the CH04.5 remedy, when the group is missing, is an
  Authentik superuser group or inherits from a parent group;
- requires the group to be declared in the CH04.5 taxonomy with the managed
  ownership stamps intact, and re-reads the attribute bag after converging the
  membership (see the mapping contract below);
- fails closed when the name is not a CH04.5-declared, non-superuser group with
  an allowed consumer chapter, or when the name is not RBAC-injection safe;
- converges only the **membership** of the Argo CD admin identity
  (`authentik_argocd_admin_username`, default `akadmin`) in that group.

Because the group is CH04.5 state, run `04.5 - Deploy Identity Foundation` before
`04.6 - Enable Argo CD SSO`. The default `PlatformInit Admins` group is a
non-superuser platform group in the CH04.5 taxonomy; `ArgoCD Admins` and
`ArgoCD Viewers` are the CH04.5-owned `application:argocd` groups that an operator
can pass through `argocd_admin_group` for a narrower Argo CD mapping. Either way
the group definition stays with CH04.5.

Converging the membership avoids the post-login state where Authentik SSO
succeeds but Argo CD sync is denied because the user only receives
`role:readonly`.

### The mapping is deterministic, non-broadening and ownership-preserving

P-CH04.6-T02 closed the remaining ownership gaps around this binding. Before any
write, `04.6 - Enable Argo CD SSO` runs a repository-only binding gate
(`validate_argocd_admin_group_binding` in
[`ch04-6-enable-argocd-sso.sh`](../scripts/ch04-6-enable-argocd-sso.sh:1)) that
refuses, naming the CH04.5 remedy, when:

| Rule | Why |
|---|---|
| the name is not `^[A-Za-z0-9][A-Za-z0-9 ._-]{0,127}$`, or carries surrounding whitespace | the name is substituted into the single `policy.csv` line, so a comma, colon, newline, quote or hash could inject a second RBAC statement and widen the mapping |
| the name is not exactly one group in [`platforminit-groups.yaml`](../groups/platforminit-groups.yaml:1) | only a CH04.5-declared group may be granted Argo CD `role:admin`; an undeclared group would be an unreviewed privilege grant |
| the taxonomy `management.managed_by` is not the CH04.5 reconciler | a group from an unowned taxonomy is not CH04.5 state |
| the declared group has `is_superuser: true` | application access is never expressed through Authentik superuser inheritance |
| the declared `consumer_chapter` is not `platform` or `CH04.6` | binding another consumer's group (for example `PlatformInit Operations`, consumed by CH05) to Argo CD admin would widen that group into platform administration |

Ownership preservation is verified twice on the write path:

1. before binding, the consumed group must carry the CH04.5 managed ownership
   stamps (`platforminit_managed_by`, `platforminit_contract_version`,
   `platforminit_owner_chapter`, `platforminit_scope`,
   `platforminit_consumer_chapter`) and `platforminit_managed_by` must name
   `ch04-5-bootstrap-identity-model`; an unstamped or foreign-owned group is
   refused, because binding it would grant unreviewed platform administration;
2. after the membership convergence, the complete attribute bag is re-read and
   compared with the pre-run snapshot. A cleared stamp, a changed value or an
   added key is a hard stop, so a run that wrote CH04.5 ownership state fails
   instead of continuing, and a repeat run leaves the same group state behind.

After the `argocd-rbac-cm` apply, CH04.6 reads the object back and fails closed
unless `policy.csv` carries exactly one `g, <group>, role:admin` binding, the
`policy.default` is `role:readonly` and the `scopes` include `groups`. A repeat
run therefore cannot have broadened Argo CD privilege, and when the mapping, the
`dex.config`, the `data.url` and the membership are already converged the run
performs no group write and no rollout restart.

## Workflow

Run:

```text
04.6 - Enable Argo CD SSO
```

Recommended inputs:

| Input | Recommended value |
|---|---|
| `artifact_run_id` | latest successful `00 - Build Platform Artifacts` run ID |
| `artifact_id` | identity artifact ID |
| `project` | `development` |
| `host_name` | `platforminit-dev-01` |
| `argocd_provider_slug` | `argocd` |
| `argocd_admin_group` | `PlatformInit Admins` |
| `authentik_argocd_admin_username` | `akadmin` |

## Validation

The single focused validator for this scope is
[`ch04-6-validate-argocd-sso.sh`](../validate/ch04-6-validate-argocd-sso.sh:1).
The workflow runs it directly after the reconciliation, so this path and
invocation contract are stable:

```bash
bash platform/identity/validate/ch04-6-validate-argocd-sso.sh
```

It is read-only (`kubectl get` plus Authentik `GET` requests) and exits non-zero on
the first `FAIL`. It asserts the Authentik rollout, the `argocd-authentik-oidc`
secret and `argocd-secret` key presence, `argocd-cm` `data.url`, the Dex connector
contract (issuer, client ID match, `$dex.authentik.clientSecret` reference,
`insecureEnableGroups`, all four scopes), the absence of a direct `oidc.config`,
the RBAC admin mapping and scopes, the discovery issuer and signing-algorithm
posture, the absence of the legacy direct-OIDC secret key, the CH04.5 admin group
consumption and admin membership, the single provider/application, the strict
redirect URI allow-list, the scope mappings, the provider/application link and the
Argo CD HTTPS endpoint. P-CH04.6-T03 also pins the login entry point: the Dex
connector id `authentik`, the login callback and logout URI on the `argocd-cm`
`data.url` origin, and an explicit boundary record that the run performed no OIDC
login and no logout. It never prints a secret value. `FAIL` is blocking;
`WARN` is informative, for example a legacy secret key that has not been retired
yet.

P-CH04.6-T02 added the ownership and mapping invariants to the live assertions:
the CH04.5 managed ownership stamps must be present and must name the CH04.5
reconciler and owner chapter with an allowed consumer chapter, and
`argocd-rbac-cm` must carry exactly one group binding (the expected admin binding)
with a `policy.default` that is not broader than `role:readonly`. A missing stamp,
a foreign owner or an extra admin binding is a blocking `FAIL`, not a warning.

P-CH04.6-T03 adds the login/logout boundary to the same run: the validator still
never performs an OIDC login or a logout, and it emits
`ARGOCD_LIVE_SSO_TEST_BOUNDARY` to record that the live SSO login/logout test is a
separate, explicitly human-approved manual step (see "Repository-only validation
versus the human-approved live SSO test" below).

Repository-only mode (no cluster, no network, non-mutating) proves the same
contract offline and is the mode to use in a WSL workspace without `kubectl`:

```bash
bash platform/identity/validate/ch04-6-validate-argocd-sso.sh --static
```

It checks that the reconciler issues no group write, asserts and re-verifies the
CH04.5 ownership stamps before binding, reads the applied mapping back, and
converges on a repeat run without rewriting membership, config or group state. It
also proves the `argocd-rbac-cm` render is byte-identical across two renders and
carries exactly one admin binding with `policy.default: role:readonly`, that the
CH04.5 taxonomy agrees with the binding constants, and it drives the extracted
admin-group binding gate with 13 fixtures - the accepted default and `ArgoCD
Admins` groups plus rejected superuser, foreign-consumer, undeclared, empty,
whitespace-padded, RBAC-injection, missing-taxonomy and mutated-taxonomy cases -
running every fixture twice so a repeat reconciliation must reach the same
decision. It exits non-zero when any control fails.

P-CH04.6-T03 added the repository-only login, redirect, session and
documentation controls to the same mode: it asserts the declared
login/redirect/logout contract literals and that this validator derives the same
Argo CD origin, login redirect path, logout path, CLI callback and scope list;
that the reconciler submits exactly three `matching_mode: strict` redirect
entries (browser login callback, CLI login callback, logout) together with a
`frontchannel` logout; that the reconciler renders the Dex connector the Argo CD
login page consumes, removes any competing direct `oidc.config` and creates the
stable `server.secretkey` that signs the Argo CD session; that the rendered
`argocd-cm` template carries the same connector, secret reference and exactly the
four contract scopes and renders byte-identically twice; and that this runbook
still documents the login, the logout/session behavior and the break-glass local
access path. Every `--static` run also prints the repository-only/live-test
boundary note, so a `--static` PASS is never presented as live SSO evidence.

Repository-only companion checks for the same contract:

```bash
bash platform/identity/validate/ch04-5-validate-identity-model-contract.sh
bash platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh
git diff --check
```

After the workflow succeeds, read-only spot checks:

```bash
kubectl -n argocd get secret argocd-authentik-oidc
kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.dex\.authentik\.clientSecret}' | wc -c
kubectl -n argocd get secret argocd-secret -o jsonpath='{.data.server\.secretkey}' | wc -c
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.dex\.config}'
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.oidc\.config}'
kubectl -n argocd get cm argocd-rbac-cm -o yaml
kubectl -n argocd rollout status deploy/argocd-dex-server
kubectl -n argocd rollout status deploy/argocd-server
```

The direct `oidc.config` check should be empty. CH04.6 intentionally uses Dex-backed Authentik SSO.
The workflow keeps the validator output as
`<PLATFORMINIT_IDENTITY_PATH>/platforminit/reports/ch04-6-argocd-sso-validate-<SHORT_SHA>.log`.

Browser test:

```text
https://argocd.<PLATFORM_BASE_DOMAIN>/login
```

Expected result: the login page shows an Authentik login option, while the local Argo CD admin account remains available for break-glass access.

## Login and logout session contract

The repository-only controls assert this contract offline; the live validator
asserts the same values against the deployed objects.

| Step | Contract |
|---|---|
| Login entry point | `https://argocd.<PLATFORM_BASE_DOMAIN>/login` renders the Dex connector `id: authentik` / `name: Authentik`, so the page offers "Log in via Authentik" while the local Argo CD admin login stays available |
| Authentik login link | Argo CD derives `https://argocd.<PLATFORM_BASE_DOMAIN>/api/dex/auth?connector_id=authentik`; the browser then leaves the Argo CD origin towards the derived Authentik issuer `https://auth.<PLATFORM_BASE_DOMAIN>/application/o/argocd/` |
| Redirect back | `https://argocd.<PLATFORM_BASE_DOMAIN>/api/dex/callback`, `matching_mode: strict`, type `authorization` |
| CLI login | `https://localhost:8085/auth/callback`, `matching_mode: strict`, type `authorization` |
| Groups claim | `include_claims_in_id_token: true` plus the `groups` scope mapping, so `argocd-rbac-cm` maps the ID token groups claim to `g, <group>, role:admin` |
| Logout | `https://argocd.<PLATFORM_BASE_DOMAIN>/logout`, `matching_mode: strict`, type `logout`, and the provider `logout_uri` equals it with `logout_method: frontchannel` |
| Session | `argocd-secret` key `server.secretkey` signs the Argo CD session cookie and the OIDC state, is created before SSO login is enabled, and is asserted for key presence only |

Both the login callback and the logout URI keep the `argocd-cm` `data.url`
origin, and the validator asserts that origin link, so a login cannot be
redirected to another host.

What a logout does and does not do:

- Argo CD logout clears the local Argo CD session cookie and, because the
  provider uses `frontchannel` logout, the browser also ends the Authentik
  session, so the next Argo CD visit requires a fresh Authentik login.
- A logout does not change authorization: the Authentik group membership and the
  `argocd-rbac-cm` mapping stay as they are, so a user who logs in again receives
  the same group-derived role until the CH04.5 taxonomy or `argocd_admin_group`
  changes.
- Rotating `argocd-secret` `server.secretkey` invalidates every live session at
  once (all users must log in again), so it is a deliberate operation and not
  part of a routine re-run.

## Break-glass and emergency local access

- The local Argo CD `admin` account remains enabled and is the break-glass path.
  It does not depend on Authentik, on the OIDC provider or on `auth.<domain>` DNS.
- Keep the `admin` password in the operator password store, never in this
  repository or in a workflow log. The validator asserts secret key presence and
  never reads a secret value, so break-glass material stays out of its scope.
- If SSO misconfiguration makes `argocd-server` crash-loop, the CH04.6 recovery
  path drops `dex.config` and `oidc.config` (see "Emergency recovery note"), and
  the local `admin` login remains the way back into Argo CD.
- Break-glass is recovery, not a steady state: after using it, reconcile
  `04.6 - Enable Argo CD SSO` again and re-run the focused validator instead of
  editing live objects by hand.

## Repository-only validation versus the human-approved live SSO test

| Aspect | Repository-only validation | Live SSO test |
|---|---|---|
| Command | `bash platform/identity/validate/ch04-6-validate-argocd-sso.sh --static` plus `git diff --check` | `04.6 - Enable Argo CD SSO` or the same validator without `--static`, then a browser login and logout |
| Proves | the reconciler, the rendered `argocd-cm`/`argocd-rbac-cm` templates, the CH04.5 taxonomy and this runbook carry the login, redirect, logout, session and RBAC contract, including the ownership-preservation and mapping-determinism invariants | the deployed provider, application and `argocd-cm`/`argocd-secret`/`argocd-rbac-cm` objects match that contract, and the browser login and logout really work |
| Does not prove | it does not prove live SSO login or logout: repository-only validation performs no OIDC login, no logout, no cluster and no network access | it does not prove the repository invariants: the live run cannot show that the reconciler preserves CH04.5 ownership or that a repeat run is convergent |
| Access | no cluster, no network, non-mutating | requires explicit human approval, because it drives a real Authentik login and inspects live objects |
| Evidence | the `--static` output and `git diff --check` | the `ch04-6-argocd-sso-validate-<SHORT_SHA>.log` artifact plus the operator's browser observation |

Repository-only validation does not prove live SSO login or logout. Running the
live SSO test requires explicit human approval and is recorded as its own manual
step; a `--static` PASS must never be filed as live SSO evidence, and the
validator prints that boundary note on every run.

## Emergency recovery note

If SSO configuration causes `argocd-server` to enter `CrashLoopBackOff`, CH04.6 removes `dex.config` and `oidc.config`, clears unhealthy server pods, and preserves a previously healthy control-plane pod where possible.

## Token verification recovery note

If the browser shows `failed to verify the token`, first clear cookies and site data for both `argocd.<domain>` and `auth.<domain>`. If it persists, verify that CH04.6 is using Dex-backed config, not direct OIDC:

```bash
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.dex\.config}'
kubectl -n argocd get cm argocd-cm -o jsonpath='{.data.oidc\.config}'
```

`dex.config` should exist and direct `oidc.config` should be empty.

## Contract drift reconciled by P-CH04.6-T01

The audit reconciled four disagreements between the script, the validator and this
runbook, all inside the CH04.6-owned files:

| Drift before the audit | Reconciled state |
|---|---|
| The validator derived the expected issuer from a hardcoded `https://auth.<domain>` host, while the script derived it from `AUTHENTIK_BASE_URL`. | Both derive the issuer from `AUTHENTIK_BASE_URL` (default `https://auth.<domain>`), and the discovered issuer must equal it. A non-default `AUTHENTIK_BASE_URL` no longer produces a false failure. |
| The script created or patched the CH04.5-managed admin group and sent `attributes: {}`, which could clear CH04.5 ownership stamps. | The group is resolved by exact-name lookup only and is never written. The CH04.6 group payload advisory of the CH04.5 identity-model validator is resolved. |
| The script wrote the unused direct-OIDC key `oidc.authentik.clientSecret` into `argocd-secret` while removing `oidc.config`, leaving a second, inert client-secret path. | The script writes only `dex.authentik.clientSecret` and removes the legacy key when present; the validator asserts exactly one OIDC client-secret key. |
| The connector scopes and the provider scope mappings were two independent literals, and the validator only checked the `groups` scope. | Both come from one scope contract, and the validator asserts all four scopes plus the provider scope mappings. |

Residual notes for the next reviewer:

- [`platform/identity/README.md`](../README.md:86) still states that the workflow
  patches `oidc.authentik.clientSecret`. That file is outside the CH04.6 task
  scope and is a follow-up documentation fix.
- The provider and application are reconciled with an unconditional `PATCH`
  (no `UNCHANGED` short-circuit), so a re-run is convergent but not write-free.

## Contract drift reconciled by P-CH04.6-T02

| Gap before the change | Reconciled state |
|---|---|
| The read-only group consumption was unproven: the live ownership check was a `WARN` and nothing verified that a run left the CH04.5 ownership stamps intact. | The consumed group must carry the CH04.5 managed ownership stamps, and the attribute bag is re-read and compared after the membership convergence; a difference is a hard stop. The live check is now a blocking `FAIL`, and preservation is proven by the pre-write stamp gate plus the post-run re-read. |
| `argocd_admin_group` accepted any existing Authentik group name and the raw name was substituted into the single `policy.csv` line. | The pre-write binding gate requires a CH04.5-taxonomy-declared, non-superuser group with an allowed consumer chapter and an RBAC-injection-safe name shape. |
| Nothing verified the applied `argocd-rbac-cm` mapping, so a repeat run could have broadened the group-to-role mapping silently. | CH04.6 reads the object back and fails closed unless exactly one `g, <group>, role:admin` binding, `policy.default: role:readonly` and a `groups` scope are present; the live validator asserts the same, and `--static` proves the render is deterministic. |
| No focused validation covered repeat reconciliation or ownership preservation in a workspace without `kubectl`. | The validator's `--static` mode exercises the repository-only controls (ownership preservation, mapping determinism, login/redirect/session contract and documentation boundary), including 13 binding-gate fixtures run twice each, plus the ownership-preservation harness documented in the task evidence. |

Residual notes for the next reviewer:

- The binding gate reads `${REPO_ROOT}/groups/platforminit-groups.yaml` from the
  identity artifact, the same relative layout the RBAC/OIDC templates already use.
  A partial artifact that omits `groups/` fails closed with the
  `ARGOCD_TAXONOMY_FILE` remedy instead of binding an unverified group.
- The ownership stamp names are CH04.5's `attribute_prefix`-derived keys. A stamp
  rename is a CH04.5 contract change: the reconciler and the live validator both
  fail closed until they are updated together.
- The live `kubectl`-based checks still cannot be observed without `kubectl`; only
  an approved `04.6 - Enable Argo CD SSO` run proves the deployed objects.

## Contract drift reconciled by P-CH04.6-T03

| Gap before the change | Reconciled state |
|---|---|
| The expected login path was only implied by the live provider checks: nothing in the repository tied the Argo CD login entry point to a connector id, and the callback/logout origin link was unasserted. | The validator asserts the Dex connector id `authentik`, keeps the login callback and the logout URI on the `argocd-cm` `data.url` origin, and the repository-only mode asserts the declared redirect/logout contract literals and the strict redirect allow-list payload. |
| Logout and session behavior and emergency local access were only implied by the recovery notes. | The runbook documents the login/logout session contract, what a logout does and does not do (session and Authentik session end, authorization unchanged, `server.secretkey` rotation consequences) and the break-glass local access path as a contract section. |
| Repository-only validation and the live SSO test were not explicitly separated, so a `--static` PASS could be read as live SSO evidence. | `--static` never performs an OIDC login or logout, prints a boundary note on every run, asserts the runbook keeps documenting that boundary, and the live mode records `ARGOCD_LIVE_SSO_TEST_BOUNDARY`; the runbook states that the live SSO test requires explicit human approval. |

Residual notes for the next reviewer:

- No automated check can observe a browser login or logout. The live SSO
  login/logout test stays a human-approved manual step with its own evidence; the
  validator only proves the contract around it.
- The login/logout redirect origin link is derived from `argocd-cm` `data.url`, so
  a `BASE_DOMAIN` change must be applied to `argocd-cm`, the Authentik provider
  redirect list and the deployment inputs together; the validator fails closed on
  a one-sided change.
