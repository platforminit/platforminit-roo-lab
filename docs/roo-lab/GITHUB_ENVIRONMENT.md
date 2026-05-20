# GitHub Environments

The platforminit-roo-lab repository uses the same environment names expected by the copied PlatformInit workflows:

```text
development
n8n
```

The `development` environment is used by CH01-CH05 PlatformInit dev workflows.
The `n8n` environment is used by n8n runtime workflows.

Org-level Actions secrets are already granted to this repository.
Environment-level secrets are only needed if a workflow explicitly requires environment-specific overrides.

Known repo-visible organization secrets include:

- AUTHENTIK_BOOTSTRAP_EMAIL
- AUTHENTIK_BOOTSTRAP_PASSWORD
- AUTHENTIK_BOOTSTRAP_TOKEN
- AUTHENTIK_POSTGRESQL_PASSWORD
- AUTHENTIK_SECRET_KEY
- AUTOMATION_SSH_PRIVATE_KEY
- AUTOMATION_SSH_PUBLIC_KEY
- DNS_API_TOKEN
- GRAFANA_ADMIN_PASSWORD
- HCLOUD_TOKEN_DEVELOPMENT
- HCLOUD_TOKEN_N8N
- HCLOUD_TOKEN_PLATFORMINIT
- HOST_LOGIN_USER
- INFRA_API_TOKEN
- INFRA_SERVER_ID
- PLATFORM_BASE_DOMAIN
- TLS_CONTACT_EMAIL

Rules:

- Do not commit secret values.
- Do not print secret values in logs.
- Do not create or use a production/customer environment in this lab repository unless explicitly approved.
- This lab repository may use development and n8n scope workflows for full dev rehearsal.
