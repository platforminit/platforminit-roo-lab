# CH04.6 - Argo CD SSO Runbook

## Goal

Enable Argo CD login through Authentik while keeping the local Argo CD admin account as a break-glass path.

CH04.6 uses Argo CD's bundled Dex server as the Authentik OIDC broker. This matches the Authentik Argo CD integration model and avoids the direct `oidc.config` callback/token-verification path that previously produced browser-side `failed to verify the token` errors.

## Authentik application/provider bootstrap

The workflow reconciles the Argo CD OAuth2/OIDC provider and application in Authentik through the Authentik API. Do not create GitHub secrets for the Argo CD client ID or client secret.

Credential ownership model:

| Value | Owner | Storage |
|---|---|---|
| Argo CD OAuth client ID | CH04.6 automation | `argocd/argocd-authentik-oidc` Kubernetes secret |
| Argo CD OAuth client secret | CH04.6 automation | `argocd/argocd-authentik-oidc` and `argocd/argocd-secret` Kubernetes secrets |
| Dex client secret reference | CH04.6 automation | `argocd/argocd-secret` key `dex.authentik.clientSecret` |
| Argo CD session signing key | CH04 / CH04.6 automation | `argocd/argocd-secret` key `server.secretkey` |
| Authentik API token | CH04.5 identity foundation | `identity/authentik-bootstrap` Kubernetes secret |

The workflow input `argocd_provider_slug` controls the Authentik application slug. The default is `argocd`.

The reconciled Authentik values are:

| Field | Value |
|---|---|
| Application name | `Argo CD` |
| Application slug | `argocd` by default |
| Provider type | `OAuth2/OpenID Connect` |
| Redirect URI mode | `Strict` |
| Redirect URI | `https://argocd.<PLATFORM_BASE_DOMAIN>/api/dex/callback` |
| CLI callback URI | `https://localhost:8085/auth/callback` |
| Logout URI | `https://argocd.<PLATFORM_BASE_DOMAIN>/logout` |
| Logout method | `Front-channel` |
| Scopes | `openid`, `profile`, `email`, `groups` |

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

CH04.6 also reconciles the matching Authentik group as an application-scoped group:

- group name: `PlatformInit Admins` by default
- `is_superuser`: `false`
- parent group: empty
- default direct member: `akadmin`

The default direct member can be overridden with `AUTHENTIK_ARGOCD_ADMIN_USERNAME` if the bootstrap administrator username differs. This avoids the post-login state where Authentik SSO succeeds but Argo CD sync is denied because the user only receives `role:readonly`.

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

After the workflow succeeds:

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
