# GitHub Environment: roo-lab-dev

The `platforminit-roo-lab` repository should use a dedicated GitHub Environment:

```text
roo-lab-dev
```

It may contain development-scope secrets equivalent to the current dev workflow environment.

Allowed development-scope secrets include:

- `HCLOUD_TOKEN_DEVELOPMENT`
- `AUTOMATION_SSH_PRIVATE_KEY`
- `AUTOMATION_SSH_PUBLIC_KEY`
- `HOST_LOGIN_USER`
- `INFRA_SERVER_ID`
- `PLATFORM_BASE_DOMAIN`
- `TLS_CONTACT_EMAIL`
- `DNS_API_TOKEN`

Rules:

- Do not add production/customer secrets.
- Do not commit secret values.
- Do not print secret values in logs.
- Use this environment only for development workflow rehearsal.
