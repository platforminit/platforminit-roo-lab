# CH02 — Host Baseline

GitHub-compatible, repo-ready CH02 host baseline with profile separation.

## Design goals

- Code/runtime separation
- Secret-free repository
- Release tarball compatible execution
- Host-local and future CI/SSH execution model support
- **Profile-aware baseline**: `platform-k3s` vs `standalone-n8n`

## Code vs runtime

- Code root: arbitrary extract path
- Runtime root: `/srv/ch01-runtime` default (layout-dependent)

## Baseline profiles

The CH02 host baseline supports two profiles that share hardening primitives
while adding profile-specific packages, firewall rules, and FIM paths.

| Profile | Description | Volume layout | Key packages | Extra ports |
|---|---|---|---|---|
| `platform-k3s` (default) | Full PlatformInit k3s host | `split` or `single` | containerd, nfs-common, open-iscsi | 80, 443, 6443 |
| `standalone-n8n` | Standalone n8n host (no Kubernetes) | `none` | docker.io, docker-compose-v2 | 80, 443 |

### Shared hardening primitives (both profiles)

- SSH hardening: root login disabled, password auth disabled, MaxStartups tuned
- Firewall: default deny incoming, allow outgoing, SSH (22) always open
- Users: `devops` and `itadmin` with scoped sudo
- FIM: `/etc/ssh/sshd_config.d/99-platforminit-hardening.conf`,
  `/etc/sudoers.d/itadmin-platforminit`
- Security: auditd, fail2ban, unattended-upgrades, AIDE

### Profile selection

The active profile is resolved in this order:

1. `PLATFORMINIT_BASELINE_PROFILE` environment variable
2. `/etc/platforminit/host-context.env` (sourced at runtime)
3. Default: `platform-k3s`

Example for a standalone n8n host:

```bash
sudo PLATFORMINIT_BASELINE_PROFILE=standalone-n8n \
  CH01_RUNTIME_ROOT=/var/lib/platforminit/ch01-runtime \
  ./scripts/apply-policy-baseline.sh
```

## Policy files

- [`policy/baseline.yaml`](policy/baseline.yaml) — Shared hardening primitives and profile definitions
- [`policy/dependencies.yaml`](policy/dependencies.yaml) — Shared apt packages and profile-specific extras

## Scripts

- [`scripts/apply-policy-baseline.sh`](scripts/apply-policy-baseline.sh) — Apply the full baseline (profile-aware)
- [`scripts/install-dependencies.sh`](scripts/install-dependencies.sh) — Install apt packages and external binaries (profile-aware)
- [`scripts/fim-check.sh`](scripts/fim-check.sh) — File integrity monitoring check (profile-aware)
- [`scripts/lib-policy.sh`](scripts/lib-policy.sh) — Shared library with profile resolution helpers
- [`scripts/security-os-check.sh`](scripts/security-os-check.sh) — Check for pending security updates
- [`scripts/security-os-apply.sh`](scripts/security-os-apply.sh) — Apply security updates
- [`scripts/grant-temporary-sudo.sh`](scripts/grant-temporary-sudo.sh) — Grant scoped temporary sudo
- [`scripts/aide-init.sh`](scripts/aide-init.sh) — Initialize AIDE database
- [`scripts/aide-check.sh`](scripts/aide-check.sh) — Run AIDE integrity check
- [`scripts/check-drift.sh`](scripts/check-drift.sh) — Check baseline drift

## Official entrypoint

```bash
sudo CH01_RUNTIME_ROOT=/srv/ch01-runtime ./scripts/apply-policy-baseline.sh
```

For standalone n8n hosts:

```bash
sudo PLATFORMINIT_BASELINE_PROFILE=standalone-n8n \
  CH01_RUNTIME_ROOT=/var/lib/platforminit/ch01-runtime \
  ./scripts/apply-policy-baseline.sh
```
