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
Argo CD HTTPS endpoint. It never prints a secret value. `FAIL` is blocking;
`WARN` is informative, for example a legacy secret key that has not been retired
yet.

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
