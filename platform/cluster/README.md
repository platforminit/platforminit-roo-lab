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
- CH04: Traefik exposure contract kept in Git and reconciled by Argo CD
- CH04: cert-manager with Cloudflare DNS-01 ClusterIssuers
- CH04: Argo CD bootstrap and GitOps ownership (AppProject + ApplicationSet)
- CH04: one validation script per platform service

### Out of scope

- Host provisioning (CH01)
- Host baseline (CH02)
- Identity layer (CH04.5, CH04.6)
- Operations stack (CH05)

## Repository layout

```
install/
  install-k3s.sh              # CH03-01: idempotent k3s install
  uninstall-k3s.sh            # CH03-02: guarded k3s uninstall
  kubeconfig-devops.sh        # CH03-03: kubeconfig for devops user
  smoke-k3s.sh                # CH03-04: workload smoke test
addons/argocd/
  bootstrap-argocd.sh                 # CH04: Argo CD bootstrap (idempotent, guarded)
  README.md                           # CH04: Argo CD ownership contract
addons/cert-manager/
  install-cert-manager.sh             # CH04: cert-manager bootstrap (idempotent, guarded)
  clusterissuer-letsencrypt-cloudflare.yaml  # CH04: GitOps-owned ClusterIssuers
  smoke/demo-cert-smoke.yaml          # CH04: staging issuance smoke manifest (never synced)
  README.md                           # CH04: DNS-01 contract
manifests/argocd/
  appproject-platform-services.yaml   # CH04: AppProject for platform services
  applicationset-platform-services.yaml  # CH04: platform services ApplicationSet
  application-argocd-self.yaml        # CH04: Argo CD self-management Application
manifests/traefik/
  traefik-helmchartconfig.yaml       # Traefik LoadBalancer config
validate/
  ch04-validate-platform-services-gitops-contract.sh  # CH04: repository-only contract check
  ch04-validate-traefik-exposure.sh                  # CH04: Traefik LoadBalancer exposure
  ch04-validate-cert-manager-dns01.sh                # CH04: cert-manager + DNS-01
  ch04-validate-argocd-bootstrap.sh                  # CH04: Argo CD bootstrap/self-management
  ch04-smoke-staging-certificate.sh                  # CH04: opt-in staging issuance smoke (mutating)
  ch03-validate-k3s-contract.sh      # CH03-05: install contract validation
  ch03-validate-reboot-survival.sh   # CH03-06: reboot survival validation
  ch02-validate.sh                   # CH02 validation (legacy)
  validate-host.sh                   # Host validation (shared)
scripts/
  ch02-orchestrator.sh               # CH02 orchestrator (legacy)
  ch02-bootstrap.sh                  # CH02 bootstrap (legacy)
  ch02-deploy.sh                     # CH02 deploy (legacy)
  ch02-reset-host.sh                 # CH02 reset (legacy)
```

## CH04 platform services (GitOps)

CH04 adds the GitOps contract on top of the CH03 cluster. Full contract:
[`docs/ch04-platform-services-gitops-contract.md`](../../docs/ch04-platform-services-gitops-contract.md).

```bash
# 1. cert-manager control plane + Cloudflare DNS-01 token secret
sudo PLATFORMINIT_ALLOW_LIVE_CERT_MANAGER_INSTALL=true \
  CF_API_TOKEN="$CF_API_TOKEN" \
  bash platform/cluster/addons/cert-manager/install-cert-manager.sh

# 2. Argo CD control plane + self-management Application
#    GitOps source defaults: PLATFORMINIT_GITOPS_REPO_URL (lab repository) and
#    PLATFORMINIT_GITOPS_TARGET_REVISION (dev). The referenced revision must be
#    pushed to the remote repository and must already contain
#    platform/cluster/manifests/argocd, so push and promote the batch branch
#    into dev before a default bootstrap. Overrides are probed with
#    git ls-remote before any cluster mutation, because Argo CD fetches from the
#    remote repository and never from the local workspace:
sudo PLATFORMINIT_ALLOW_LIVE_ARGOCD_BOOTSTRAP=true \
  bash platform/cluster/addons/argocd/bootstrap-argocd.sh
```

`argocd-self` runs in Argo CD's built-in `default` project: the `platform-services` AppProject it
reconciles lives inside its own source directory, so it cannot be a prerequisite of the Application
that creates it (fresh-cluster bootstrap ordering).

After bootstrap, Argo CD owns the `platform-services` AppProject and ApplicationSet
([`manifests/argocd/`](manifests/argocd:1)) and deploys Traefik exposure plus the cert-manager
ClusterIssuers from Git. Manual `kubectl apply` is limited to bootstrap, the documented
pre-promotion rehearsal (which requires the revision to be pushed first) and break-glass recovery.

The `platform-services` AppProject grants no wildcard permissions: it allows only the explicitly
demonstrated kinds (`cert-manager.io/ClusterIssuer`, namespaced `helm.cattle.io/HelmChartConfig`) in
the `kube-system` and `cert-manager` destinations the generated Applications target. Both bootstrap
scripts apply only a digest-verified upstream manifest: the manifest URL is a fixed HTTPS origin (not
an operator override), the version tag must match `vMAJOR.MINOR.PATCH` and have a committed SHA-256 pin
in the script, and only the verified file is handed to `kubectl apply`. Details and the pin-refresh
procedure: [`docs/ch04-platform-services-gitops-contract.md`](../../docs/ch04-platform-services-gitops-contract.md).

### CH04 validation

```bash
# Repository-only contract check (no cluster access required)
bash platform/cluster/validate/ch04-validate-platform-services-gitops-contract.sh

# Live cluster checks (read-only)
sudo bash platform/cluster/validate/ch04-validate-traefik-exposure.sh
sudo bash platform/cluster/validate/ch04-validate-cert-manager-dns01.sh
sudo bash platform/cluster/validate/ch04-validate-argocd-bootstrap.sh

# Issuance evidence (opt-in, mutating, self-cleaning, staging only)
sudo PLATFORMINIT_ALLOW_STAGING_CERT_SMOKE=true \
  bash platform/cluster/validate/ch04-smoke-staging-certificate.sh
```

The read-only cert-manager check proves the issuer/solver/token wiring; only the smoke check proves
that a certificate was actually issued. The Traefik validator fails (not warns) when no
LoadBalancer IP or hostname is bound after `LB_WAIT_TIMEOUT` (default 60s, validated range 15-900s).

Both wait inputs are range-checked before the first cluster call, and the smoke check refuses any
namespace/object collision instead of adopting it: it creates uniquely named, run-labelled resources
(`SMOKE_NAMESPACE_PREFIX` + `SMOKE_RUN_ID`, `SMOKE_TIMEOUT` default 300s / range 30-1800s) and deletes
exactly those resources on exit — success or failure — with no keep-resources bypass.

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
