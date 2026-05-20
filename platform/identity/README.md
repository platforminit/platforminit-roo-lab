# CH04.5 - Identity Foundation

CH04.5 introduces the PlatformInit identity foundation based on Authentik. The identity runtime is owned by CH04.5. Old CH06 compatibility files have been removed from the normal lifecycle.

## Scope

- Deploy Authentik into the `identity` namespace.
- Publish the Authentik Web UI at `https://auth.<PLATFORM_BASE_DOMAIN>`.
- Bootstrap PlatformInit identity groups and selected technical users.
- Keep application-local break-glass accounts where the application requires them.
- Provide SSO foundation for Argo CD and the CH05 operations WebUIs.

## Runtime model

| Component | Namespace | Public ingress | Notes |
|---|---|---:|---|
| Authentik server | `identity` | yes | `https://auth.<base-domain>` |
| Authentik worker | `identity` | no | background jobs and bootstrap |
| PostgreSQL | `identity` | no | embedded chart for development/homelab baseline |

## Required GitHub secrets

- `AUTHENTIK_SECRET_KEY`
- `AUTHENTIK_POSTGRESQL_PASSWORD`
- `AUTHENTIK_BOOTSTRAP_PASSWORD`

## Optional GitHub secrets

- `AUTHENTIK_BOOTSTRAP_EMAIL`
- `AUTHENTIK_BOOTSTRAP_TOKEN`

If `AUTHENTIK_BOOTSTRAP_EMAIL` is empty, the deploy workflow uses `admin@<PLATFORM_BASE_DOMAIN>`.
If `AUTHENTIK_BOOTSTRAP_TOKEN` is empty, the remote deploy script preserves the existing cluster secret if present, otherwise generates a token once.

## First login

```text
https://auth.<PLATFORM_BASE_DOMAIN>/
```

Default administrative user:

```text
akadmin
```

Password source:

```text
AUTHENTIK_BOOTSTRAP_PASSWORD
```

If the automated bootstrap did not run because Authentik was previously initialized, use the existing `akadmin` password or perform the initial setup flow:

```text
https://auth.<PLATFORM_BASE_DOMAIN>/if/flow/initial-setup/
```

Keep the trailing slash.

## Next phase

After the identity foundation is healthy:

1. Run `04.6 - Enable Argo CD SSO` because Argo CD already exists after CH04.
2. Run the CH05 operations stack: Zabbix, OpenObserve and Vector.
3. Run `05.3 - Enable Checkmk Trusted-Header SSO` to configure native Zabbix SAML and OpenObserve Enterprise OIDC through Authentik.

## CH04.6 Argo CD SSO

Argo CD uses an Authentik OIDC provider configured by `04.6 - Enable Argo CD SSO`.

Credential ownership model:

- The workflow reads `identity/authentik-bootstrap` for the Authentik API token.
- The workflow creates or reuses `argocd/argocd-authentik-oidc`.
- The workflow patches `argocd/argocd-secret` with `oidc.authentik.clientSecret`.
- No `ARGOCD_OIDC_CLIENT_ID` or `ARGOCD_OIDC_CLIENT_SECRET` GitHub secrets are required for the normal path.

Default Authentik provider/application slug: `argocd`.
Default admin group mapping: `PlatformInit Admins` → `role:admin`.

## CH05 Operations SSO

Zabbix and OpenObserve use native application SSO through Authentik: Zabbix via SAML and OpenObserve Enterprise via OIDC.

The public WebUI ingresses are Argo CD-owned as part of the CH05 operations stack. `05.3 - Enable Checkmk Trusted-Header SSO` only reconciles the Authentik providers/applications and app-level SSO settings.

Protected URLs:

```text
https://zabbix.<PLATFORM_BASE_DOMAIN>
https://logs.<PLATFORM_BASE_DOMAIN>
```
