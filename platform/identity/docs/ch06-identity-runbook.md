# Deprecated CH06 Identity Runbook

> Status: deprecated compatibility documentation. No workflow, script or validator in this
> repository invokes a CH06 identity path, and the `ch06-*` naming must not receive new behaviour.
> Canonical references: [`ch04-5-identity-foundation.md`](ch04-5-identity-foundation.md),
> [`ch04-6-argocd-sso-runbook.md`](ch04-6-argocd-sso-runbook.md) and the
> [`ch04-5-identity-ownership-inventory.md`](ch04-5-identity-ownership-inventory.md).

CH06 is retained only for compatibility. Normal lifecycle execution uses CH04.5 for Authentik and separate SSO workflows for applications.

## Current active identity lifecycle

| Workflow | Purpose |
|---|---|
| `04.5 - Deploy Identity Foundation` | Authentik core and identity model |
| `04.6 - Enable Argo CD SSO` | Argo CD login through Authentik |
| `05.3 - Enable Checkmk Trusted-Header SSO` | Zabbix SAML and OpenObserve Enterprise OIDC through Authentik |

## Required secrets for Authentik

```text
AUTHENTIK_SECRET_KEY
AUTHENTIK_POSTGRESQL_PASSWORD
AUTHENTIK_BOOTSTRAP_PASSWORD
```

## Validation commands

```bash
kubectl -n identity get pods -o wide
kubectl -n identity get ingress,certificate,secrets
kubectl -n identity rollout status deploy/authentik-server
kubectl -n identity rollout status deploy/authentik-worker
```

Expected public endpoint:

```text
https://auth.<PLATFORM_BASE_DOMAIN>/
```

## Break-glass rule

Do not remove application-local recovery access until each application-specific SSO path has been validated.
