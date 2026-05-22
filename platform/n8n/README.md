# N8N standalone host

This component defines a deliberately small standalone n8n host model for the
`n8n` Hetzner project.

## Architecture

```text
Hetzner n8n project
└── CX23 / Ubuntu 24.04
    ├── Docker Compose
    ├── n8n container
    ├── PostgreSQL container
    ├── Caddy container
    └── local bind-mounted data under /srv/n8n
```

Decisions:

- No attached Hetzner Volume for the first iteration.
- No k3s on the n8n host.
- No local observability stack on the n8n host.
- The n8n host is a future remote monitoring target for the central Checkmk
  instance, not a monitoring platform.
- Caddy owns HTTP/HTTPS and ACME certificate handling.
- n8n uses its own login in the first iteration.

## Runtime layout

```text
/srv/n8n/
├── .env
├── Caddyfile
├── docker-compose.yml
├── data/
├── postgres/
├── caddy-data/
└── caddy-config/
```

This is still container-based persistence. It uses host-local bind mounts on the
CX23 root disk rather than an attached Hetzner block volume.

## Required GitHub secrets

Environment: `n8n`

```text
HCLOUD_TOKEN_N8N
AUTOMATION_SSH_PRIVATE_KEY
AUTOMATION_SSH_PUBLIC_KEY
HOST_LOGIN_USER
N8N_ENCRYPTION_KEY
N8N_POSTGRES_PASSWORD
TLS_CONTACT_EMAIL
```

One-time runtime secret setup:

```bash
openssl rand -hex 32 | gh secret set N8N_ENCRYPTION_KEY --env n8n --repo platforminit/platforminit-platform
openssl rand -hex 32 | gh secret set N8N_POSTGRES_PASSWORD --env n8n --repo platforminit/platforminit-platform
printf '%s' 'admin@example.com' | gh secret set TLS_CONTACT_EMAIL --env n8n --repo platforminit/platforminit-platform
```

`N8N_ENCRYPTION_KEY` must remain stable after first deployment. n8n uses it to
encrypt stored credentials, so replacing it later can make existing credentials
unreadable.

## Host creation

Use the existing host lifecycle workflow:

```text
01 - Create or Rebuild Host
project = n8n
host_name = platforminit-n8n-01   # current example — derived from platform/projects/n8n.yaml server_prefix + default index
server_type = cx23
region = hel1
volume_layout = none
image = ubuntu-24.04
```

Then run the usual host access/baseline flows for the n8n project before
runtime deployment.

## Runtime deployment

Use:

```text
N8N - Deploy Standalone Runtime
```

Recommended inputs:

```text
action = deploy
project = n8n
host_name = platforminit-n8n-01   # current example — derived from platform/projects/n8n.yaml server_prefix + default index
n8n_domain = n8n.sysadminhomelab.hu
```

After the workflow succeeds, open the n8n URL and create the first owner account
through the normal n8n setup screen.

## Authentication note

The first iteration uses n8n's built-in login. Native SAML/OIDC SSO is not part
of the default open self-hosted path and should not block the initial host.
Google OAuth credentials inside n8n are for workflow integrations, not for
logging in to the n8n UI.


## Host lifecycle volume contract

For the `n8n` project, `01 - Create or Rebuild Host` must resolve `volume_layout=project-default` to `none`. The CX23 n8n host is root-disk-only: no Hetzner Volume should be created, attached, mounted, or expected by bootstrap/baseline workflows.
