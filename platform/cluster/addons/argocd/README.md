# CH04 — Argo CD bootstrap and self-management

## Contract

Argo CD is the GitOps control plane for the platform track.

1. **Bootstrap (once, imperative):** [`bootstrap-argocd.sh`](bootstrap-argocd.sh:1) installs Argo CD, switches the server to ingress mode (`server.insecure=true`), waits for the control plane, and applies the committed `argocd-self` Application.
2. **Steady state (GitOps):** Argo CD owns
   - [`appproject-platform-services.yaml`](../../manifests/argocd/appproject-platform-services.yaml:1)
   - [`applicationset-platform-services.yaml`](../../manifests/argocd/applicationset-platform-services.yaml:1)

   those manifests are reconciled from Git by the [`argocd-self`](../../manifests/argocd/application-argocd-self.yaml:1) Application. The ApplicationSet then generates the platform service Applications (Traefik exposure, cert-manager issuers).

After bootstrap, `kubectl apply` must not be used to deploy platform services.

## Bootstrap

```bash
sudo PLATFORMINIT_ALLOW_LIVE_ARGOCD_BOOTSTRAP=true \
  bash platform/cluster/addons/argocd/bootstrap-argocd.sh
```

- `ARGO_VERSION` selects the upstream release (default `v2.10.7`). It must match `vMAJOR.MINOR.PATCH`
  **and** have a committed pin (`ARGO_PINNED_VERSION` / `ARGO_PINNED_MANIFEST_SHA256`); an unpinned
  version is refused instead of installed unverified.
- The install manifest is fetched over HTTPS from a fixed origin, its SHA-256 is compared with the
  committed pin, and only the verified temporary copy is applied. The manifest URL is not
  operator-overridable (the previous arbitrary URL override was removed by the security fix batch).
- `ARGOCD_SYNC_TIMEOUT` bounds the wait for `argocd-self` to reach `Synced` (default 300s, validated
  range 30-1800s). The value must be plain base-10 digits: it is evaluated inside Bash arithmetic by the
  wait helpers, so an arithmetic payload or any nonnumeric input is refused before the first arithmetic
  use and the first cluster call instead of executing a command.
- Host prerequisites: `git` (reachability probe), `curl` and `sha256sum` (verified download).
- The script is idempotent: the namespace, install manifest, `server.insecure` patch, and self Application are all applied/checked conditionally.

### Refreshing the upstream pin

Only after reviewing the upstream release notes:

```bash
curl --fail --location --proto '=https' -o /tmp/argocd-install.yaml \
  https://raw.githubusercontent.com/argoproj/argo-cd/v2.10.7/manifests/install.yaml
sha256sum /tmp/argocd-install.yaml
```

Update `ARGO_PINNED_VERSION` + `ARGO_PINNED_MANIFEST_SHA256` in [`bootstrap-argocd.sh`](bootstrap-argocd.sh:1)
in the same commit and run
[`ch04-validate-platform-services-gitops-contract.sh`](../../validate/ch04-validate-platform-services-gitops-contract.sh:1).
The digest is trust-on-first-use for the official release asset, so the change must be reviewed.

### GitOps source inputs

| Input | Default | Notes |
|---|---|---|
| `PLATFORMINIT_GITOPS_REPO_URL` | `https://github.com/platforminit/platforminit-roo-lab.git` | Must be one of the two PlatformInit repositories and must not embed credentials |
| `PLATFORMINIT_GITOPS_TARGET_REVISION` | `dev` | Must be pushed to the remote repository and must contain `platform/cluster/manifests/argocd` |
| `PLATFORMINIT_ALLOW_STABLE_GITOPS_SOURCE` | unset | Required (`true`) to accept the stable `platforminit-platform` repository |

The committed `repoURL`/`targetRevision` in [`application-argocd-self.yaml`](../../manifests/argocd/application-argocd-self.yaml:1)
and [`applicationset-platform-services.yaml`](../../manifests/argocd/applicationset-platform-services.yaml:1)
must match the script defaults; the repository-only validator enforces that invariant.

**Reachability:** Argo CD fetches from the remote repository, never from the local workspace, so the
selected revision must already be pushed. Any override is probed with `git ls-remote` before the
first cluster mutation (`git` is therefore required on the bootstrap host) and the bootstrap aborts
when the revision does not exist remotely. A branch that only exists locally — for example a
delivery that was never pushed by the controller — is never reconciliation evidence. Credentials are
never embedded in `PLATFORMINIT_GITOPS_REPO_URL`; the bootstrap refuses a URL that carries userinfo.

**Private repositories** additionally need an Argo CD repository registration plus git credentials
for the CLI on the bootstrap host. The secret-safe registration procedure (token typed at a prompt,
never written to a file, shell history or Git) is documented in
[`docs/ch04-platform-services-gitops-contract.md`](../../../../docs/ch04-platform-services-gitops-contract.md:1).

Overriding the inputs performs a **pre-promotion rehearsal**: the manifests are rendered with the
requested, pushed source, the rendered AppProject and ApplicationSet are registered once, and
automated self-management sync is disabled for that session (otherwise Argo CD would reconcile
`argocd-self` straight back to the committed default). Re-run without overrides after the change is
promoted into `dev` to restore automated self-management.

## Safety properties

- `argocd-self` runs in the built-in `default` project: the `platform-services` AppProject lives inside the directory `argocd-self` reconciles, so requiring it would make bootstrap impossible on a fresh cluster. The scoped AppProject still governs the generated platform-service Applications.
- `argocd-self` has `prune: false`: pruning an Application that owns its own AppProject/ApplicationSet could delete the GitOps control path.
- The `platform-services` AppProject allows only the two known PlatformInit repositories, only the `kube-system` and `cert-manager` destinations the generated Applications use, and only the explicitly demonstrated resource kinds (`cert-manager.io/ClusterIssuer`, namespaced `helm.cattle.io/HelmChartConfig`). Wildcard group/kind permissions are forbidden and the focused validator fails if either the wildcard or a synced-but-unlisted kind comes back.
- Ingress/TLS for the Argo CD UI is owned by CH03 (see [`platform/platform-services/ingress/`](../../../platform-services/ingress:1)) and CH04.6 SSO integration; this addon does not render certificates.

## Validation

```bash
sudo bash platform/cluster/validate/ch04-validate-argocd-bootstrap.sh
```
