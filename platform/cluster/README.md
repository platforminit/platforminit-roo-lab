# sysadminhomelab-ch02

Known-good CH02 repo rebuild manual CI/CD célra.

Ez a repo a működő on-host tarball logikáját viszi át GitHub repository formába úgy, hogy:
- a tarball szemantikája marad a forrásigazság,
- egyetlen hivatalos deploy entrypoint van,
- a GitHub Actions csak artifact build + remote deploy szerepet kap.

## Scope

CH02 feladata:
- k3s install / repair
- devops kubeconfig
- Traefik HelmChartConfig
- cert-manager install
- Cloudflare token secret
- ClusterIssuer apply
- wildcard DNS rekord biztosítása
- Argo CD bootstrap
- validáció

Nem scope:
- host provisioning
- CH01 baseline build
- GitOps sync ownership

## Repository layout

- `install/` - k3s install helpers
- `addons/argocd/` - Argo CD bootstrap
- `addons/cert-manager/` - cert-manager és issuer manifestek
- `manifests/traefik/` - Traefik HelmChartConfig
- `validate/` - known-good validátorok
- `scripts/ch02-orchestrator.sh` - egyetlen hivatalos deploy entrypoint
- `.github/workflows/` - manual build + deploy pipeline

## Required GitHub secrets

- `HCLOUD_TOKEN`
- `HCLOUD_SERVER_ID`
- `HCLOUD_SSH_PRIVATE_KEY`
- `CF_API_TOKEN_DNS`

## Manual flow

1. `build-ch02-artifact`
2. `deploy-ch02-from-artifact`
   - input: az előző workflow run ID-ja
   - `deploy_mode`:
     - `clean-slate` = teljes CH02 reset + friss telepítés
     - `repair` = meglévő állapotra fut rá, wipe nélkül

## Design rule

Először parity, utána refaktor.


## Deploy modes

- `clean-slate` az ajánlott candidate host / hibajavítás utáni újratelepítéshez.
- `repair` csak akkor használd, ha a hoston már ismerten egészséges CH02 állapot van és nem akarsz wipe-ot.
