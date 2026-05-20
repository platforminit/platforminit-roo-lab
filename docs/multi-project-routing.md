# Multi-project Hetzner routing

PlatformInit no longer treats `project` as a cosmetic label. The workflow input `project` is the routing key for the Hetzner API token, SSH key name, server prefix, and volume namespace.

Supported projects are defined under `platform/projects/`:

- `development` -> `HCLOUD_TOKEN_DEVELOPMENT`
- `n8n` -> `HCLOUD_TOKEN_N8N`
- `platforminit` -> `HCLOUD_TOKEN_PLATFORMINIT`

The legacy `INFRA_API_TOKEN` path is deprecated. Runtime workflows should call `.github/actions/resolve-target-host` with `project`, `host_name`, `role`, and optional overrides only. The composite action resolves the correct token via `tools/platforminit_ops/hcloud_resolve.py`.

SSH keys are Hetzner-project scoped. The host lifecycle workflow registers the configured automation public key in the selected Hetzner project when missing.

Local secret bootstrap uses repo-scoped GitHub secrets by default:

```bash
.local_secrets/development_api_key
.local_secrets/n8n_api_key
.local_secrets/platforminit_api_key

bash scripts/bootstrap-org-secrets.sh
```
