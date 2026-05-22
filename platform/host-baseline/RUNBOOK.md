# CH02 Host Baseline Runbook

## Required runtime structure

```text
/var/lib/platforminit/ch01-runtime/   (volume_layout=none, standalone-n8n)
/srv/ch01-runtime/                    (volume_layout=single, platform-k3s)
/srv/data/platforminit/ch01-runtime/  (volume_layout=split, platform-k3s)
  reports/
  state/
  secrets/
```

## Required secret file

```text
<runtime_root>/secrets/authorized_keys
```

## Baseline profiles

The CH02 baseline supports two profiles:

- **`platform-k3s`** (default) — Full PlatformInit k3s host with Kubernetes, ingress, identity, observability
- **`standalone-n8n`** — Standalone n8n host with Docker Compose, Caddy, no Kubernetes

Profile is resolved via `PLATFORMINIT_BASELINE_PROFILE` env var or
`/etc/platforminit/host-context.env`.

## Execution

### platform-k3s (default)

```bash
sudo CH01_RUNTIME_ROOT=/srv/ch01-runtime ./scripts/apply-policy-baseline.sh
```

### standalone-n8n

```bash
sudo PLATFORMINIT_BASELINE_PROFILE=standalone-n8n \
  CH01_RUNTIME_ROOT=/var/lib/platforminit/ch01-runtime \
  ./scripts/apply-policy-baseline.sh
```

## Reports

- `fim-baseline-<ts>.txt`
- `validate-host-<ts>.md`
- `validate-host-<ts>.json`
- `validate-host-latest.md`
- `validate-host-latest.json`

## Baseline workflow

- `scripts/apply-policy-baseline.sh` applies the full baseline (profile-aware)
- `scripts/fim-check.sh` runs file integrity monitoring (profile-aware)
- `scripts/install-dependencies.sh` installs packages (profile-aware)
- `scripts/security-os-check.sh` checks for pending security updates
- `scripts/security-os-apply.sh` applies security updates
- `scripts/grant-temporary-sudo.sh` grants scoped temporary sudo
- `scripts/aide-init.sh` initializes AIDE database
- `scripts/aide-check.sh` runs AIDE integrity check
- `scripts/check-drift.sh` checks baseline drift

## Remote execution

```bash
# platform-k3s
sudo ./remote/apply-baseline-remote.sh /tmp/platforminit-run auto "<ssh-pub-key>"

# standalone-n8n
sudo PLATFORMINIT_BASELINE_PROFILE=standalone-n8n \
  ./remote/apply-baseline-remote.sh /tmp/platforminit-run auto "<ssh-pub-key>"
```
