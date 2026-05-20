# CH04.5 - Identity Foundation

CH04.5 defines the base identity model before application-specific SSO bindings are enabled.

The goal is to avoid a single broad admin group and instead create scoped groups that can later be mapped independently to Argo CD, Authentik and CH05 operations WebUIs.

## Scope

CH04.5 owns:

- PlatformInit identity group taxonomy.
- Bootstrap admin membership reconciliation.
- Application-scoped access groups.
- Technical user definitions for later controlled enablement.

CH04.5 does not own:

- Argo CD SSO runtime wiring.
- CH05 operations SSO runtime wiring.
- User password lifecycle.
- Production user onboarding.

Those remain separate lifecycle tasks.

## Files

```text
platform/identity/
├── docs/
│   └── ch04-5-identity-foundation.md
├── groups/
│   └── platforminit-groups.yaml
├── users/
│   └── bootstrap-technical-users.yaml
├── scripts/
│   └── ch04-5-bootstrap-identity-model.sh
└── validate/
    └── ch04-5-validate-identity-model.sh
```

The `.yaml` files are YAML-compatible JSON on purpose. This keeps the bootstrap scripts dependency-free and avoids requiring `yq` or PyYAML on the host.

## Group model

| Group | Scope | Purpose |
|---|---|---|
| `PlatformInit Admins` | platform | Transitional platform admin group. |
| `PlatformInit Operators` | platform | Operational users without global superuser rights. |
| `ArgoCD Admins` | Argo CD | Argo CD admin RBAC group. |
| `ArgoCD Viewers` | Argo CD | Argo CD read-only RBAC group. |
| `Operations Admins` | operations | CH05 operations WebUI admin group. |
| `Operations Viewers` | operations | CH05 operations WebUI viewer group. |
| `Zabbix Admins` | Zabbix | Zabbix operational monitoring admin group. |
| `OpenObserve Admins` | OpenObserve | OpenObserve RCA log admin group. |
| `Authentik Admins` | Authentik | Authentik administration group. |

Only `Authentik Admins` is marked as an Authentik superuser group. Application groups must stay application-scoped.

## Bootstrap membership

By default, CH04.5 attaches the bootstrap Authentik admin user to the initial operational groups:

- `PlatformInit Admins`
- `ArgoCD Admins`
- `Operations Admins`
- `Zabbix Admins`
- `OpenObserve Admins`
- `Authentik Admins`

The username defaults to `akadmin` and can be overridden:

```bash
AUTHENTIK_BOOTSTRAP_ADMIN_USERNAME=akadmin platform/identity/scripts/ch04-5-bootstrap-identity-model.sh
```

## Technical users

Technical users are defined but not created by default. This is intentional until the project defines:

- Password generation and rotation.
- Disablement policy.
- Ownership.
- Audit trail.
- Migration from bootstrap users to real users.

## Runbook

```bash
platform/identity/scripts/ch04-5-bootstrap-identity-model.sh
platform/identity/validate/ch04-5-validate-identity-model.sh
```
