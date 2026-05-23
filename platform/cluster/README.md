# PlatformInit — k3s Cluster (CH03)

## Scope

CH03 defines the k3s single-node install and validation contract for the platform track.

### In scope

- k3s single-node install (idempotent)
- kubeconfig provisioning for the `devops` user
- `/srv/data/k3s` data-dir contract (see [`docs/k3s-data-dir-storage-contract.md`](../../docs/k3s-data-dir-storage-contract.md))
- Traefik ingress with LoadBalancer service type and ServiceLB
- Service exposure via Traefik (ports 80/443)
- Reboot survival validation
- Validation scripts

### Out of scope

- Host provisioning (CH01)
- Host baseline (CH02)
- cert-manager, ClusterIssuer, Cloudflare DNS (CH04)
- Argo CD bootstrap (CH04)
- Identity layer (CH04.5)
- Operations stack (CH05)

## Repository layout

```
install/
  install-k3s.sh              # CH03-01: idempotent k3s install
  uninstall-k3s.sh            # CH03-02: guarded k3s uninstall
  kubeconfig-devops.sh        # CH03-03: kubeconfig for devops user
  smoke-k3s.sh                # CH03-04: workload smoke test
validate/
  ch03-validate-k3s-contract.sh      # CH03-05: install contract validation
  ch03-validate-reboot-survival.sh   # CH03-06: reboot survival validation
  ch02-validate.sh                   # CH02 validation (legacy)
  validate-host.sh                   # Host validation (shared)
manifests/traefik/
  traefik-helmchartconfig.yaml       # Traefik LoadBalancer config
scripts/
  ch02-orchestrator.sh               # CH02 orchestrator (legacy)
  ch02-bootstrap.sh                  # CH02 bootstrap (legacy)
  ch02-deploy.sh                     # CH02 deploy (legacy)
  ch02-reset-host.sh                 # CH02 reset (legacy)
```

## Storage contract

k3s data must live under `/srv/data/k3s` so local-path PVC storage does not silently grow on the wrong filesystem/partition.

See [`docs/k3s-data-dir-storage-contract.md`](../../docs/k3s-data-dir-storage-contract.md) for audit commands and remediation.

## Install

```bash
# As root on the target host:
sudo PLATFORMINIT_ALLOW_LIVE_K3S_INSTALLER=true bash platform/cluster/install/install-k3s.sh
```

The install script is idempotent. If k3s is already installed with the expected version, it ensures config and service state without re-installing.

### Supply-chain note

The script uses the upstream live installer (`curl https://get.k3s.io | sh -`) with a pinned `K3S_VERSION`. Because the installer is fetched live without checksum verification, the `PLATFORMINIT_ALLOW_LIVE_K3S_INSTALLER=true` environment variable must be set to acknowledge this supply-chain trade-off. This prevents accidental silent installs.

## Post-install kubeconfig

```bash
sudo bash platform/cluster/install/kubeconfig-devops.sh devops
```

This copies the admin kubeconfig to `~devops/.kube/config` and rewrites the API endpoint to `https://127.0.0.1:6443` (or a custom endpoint via `K3S_API_ENDPOINT`).

## Validation

### Install contract validation (safe, non-mutating)

```bash
sudo bash platform/cluster/validate/ch03-validate-k3s-contract.sh
```

Validates:
- k3s binary and service active/enabled
- data-dir exists and follows `/srv` contract
- `config.yaml` has correct data-dir
- node Ready
- Traefik service exists with ports 80/443
- kubeconfig accessible
- kubectl can access cluster

### Reboot survival validation

```bash
# After a host reboot:
sudo bash platform/cluster/validate/ch03-validate-reboot-survival.sh
```

Validates:
- k3s service enabled and active after boot
- data-dir persists on `/srv`
- kubeconfig accessible
- node becomes Ready
- Traefik service recovers
- systemd journal clean (no error/failed/fatal entries)

### Smoke test (creates temporary namespace)

```bash
sudo bash platform/cluster/install/smoke-k3s.sh
```

Deploys an nginx workload, exposes it as a service, and validates in-cluster service discovery. The namespace is cleaned up on exit.

## Uninstall

```bash
sudo bash platform/cluster/install/uninstall-k3s.sh
```

Includes guards against empty or root data-dir paths. The script expects `K3S_DATA_DIR` to be `/srv/data/k3s` (the standard PlatformInit data-dir). If a non-standard path is used, set `K3S_DATA_DIR_ALLOW_UNSAFE=true` to override the guard.

## Design rules

- All scripts use `set -euo pipefail`.
- All scripts validate required environment variables.
- No `eval`, no unquoted variables, no unguarded `rm -rf`.
- Validation scripts are safe to run on a running host (non-mutating).
- Reboot survival validation does NOT trigger a reboot.
