# CH04 — cert-manager addon (Cloudflare DNS-01)

## Ownership split

| Phase | Owner | Artifact |
|---|---|---|
| Bootstrap (once) | operator script | [`install-cert-manager.sh`](install-cert-manager.sh:1) installs cert-manager and syncs the Cloudflare API token secret |
| GitOps (steady state) | Argo CD | [`clusterissuer-letsencrypt-cloudflare.yaml`](clusterissuer-letsencrypt-cloudflare.yaml:1) via the `platform-cert-manager-issuers` Application |

`kubectl apply` of the ClusterIssuers is intentionally **not** part of the bootstrap script: once Argo CD is bootstrapped, issuers are reconciled from Git.

## Bootstrap

```bash
sudo PLATFORMINIT_ALLOW_LIVE_CERT_MANAGER_INSTALL=true \
  CF_API_TOKEN="$CF_API_TOKEN" \
  bash platform/cluster/addons/cert-manager/install-cert-manager.sh
```

- `CM_VERSION` selects the upstream release (default `v1.14.5`). It must match `vMAJOR.MINOR.PATCH`
  **and** have a committed pin (`CM_PINNED_VERSION` / `CM_PINNED_MANIFEST_SHA256`); an unpinned version
  is refused instead of installed unverified.
- The manifest URL is built from a fixed HTTPS origin and is not operator-overridable; the download is
  written to a temporary file, its SHA-256 is compared with the committed pin, and only the verified
  copy is applied. The temporary file is removed on exit.
- Host prerequisites: `kubectl`, `curl`, `sha256sum`.
- `CF_API_TOKEN` is optional; when unset the secret sync is skipped and the operator must create `cloudflare-api-token-secret` manually. The token value is never printed.
- The script is idempotent: re-running re-applies the pinned manifest and re-syncs the secret.

### Refreshing the upstream pin

Only after reviewing the upstream release notes:

```bash
curl --fail --location --proto '=https' -o /tmp/cert-manager.yaml \
  https://github.com/cert-manager/cert-manager/releases/download/v1.14.5/cert-manager.yaml
sha256sum /tmp/cert-manager.yaml
```

Update `CM_PINNED_VERSION` + `CM_PINNED_MANIFEST_SHA256` in [`install-cert-manager.sh`](install-cert-manager.sh:1)
in the same commit and run
[`ch04-validate-platform-services-gitops-contract.sh`](../../validate/ch04-validate-platform-services-gitops-contract.sh:1).
The digest is trust-on-first-use for the official release asset, so the change must be reviewed.

## DNS-01 contract

- Solvers use `dns01.cloudflare.apiTokenSecretRef` → secret `cloudflare-api-token-secret`, key `api-token`, namespace `cert-manager`.
- Two issuer sets are declared: `letsencrypt-staging` (smoke tests) and `letsencrypt-prod`.
- Certificate secrets stay in the namespace of the workload that requests them; no cross-namespace TLS secret reuse.
- No secret material is committed to Git. `docs/secrets-reference.md` documents the operator-side handling.

## Layout note

The Argo CD Application for issuers points at this directory with `directory.recurse: false`. Smoke-test manifests therefore live in [`smoke/`](smoke/demo-cert-smoke.yaml:1) so they are never synced into the live cluster.

## Staging issuance smoke check (opt-in, mutating)

```bash
sudo PLATFORMINIT_ALLOW_STAGING_CERT_SMOKE=true \
  bash platform/cluster/validate/ch04-smoke-staging-certificate.sh
```

- Guarded by `PLATFORMINIT_ALLOW_STAGING_CERT_SMOKE=true`; the default validators stay read-only.
- Run-owned: applies [`smoke/demo-cert-smoke.yaml`](smoke/demo-cert-smoke.yaml:1) under a per-run identity. `SMOKE_RUN_ID` (default UTC timestamp + PID) names the run-owned namespace, Certificate and target TLS Secret and labels them with `platforminit.io/smoke-run`; `SMOKE_NAMESPACE_PREFIX` (default `cert-manager-smoke`) sets the namespace prefix. A pre-existing object for the same run id is refused, never adopted, overwritten or deleted.
- Bounded: waits at most `SMOKE_TIMEOUT` (default 300s, validated range 30-1800s) for `Ready=True`; the value is range-checked before the first cluster call.
- Staging only: refuses any issuer other than `letsencrypt-staging`, so the Let's Encrypt production rate limit is never consumed.
- Self-cleaning: cleans up the Certificate, the issued TLS Secret and the run-owned namespace on exit, success or failure. There is no keep-resources bypass, so an accepted run can never strand resources.
- On failure prints Certificate conditions plus `Order`/`Challenge` state and reason only — never Secret values, tokens or raw dumps.

The DNS name and issuer live in the committed smoke manifest, so there is a single source of truth for
what the smoke check requests.

## Validation

```bash
# Read-only: CRDs, control plane, issuers, solver wiring, token secret
sudo bash platform/cluster/validate/ch04-validate-cert-manager-dns01.sh
```

The read-only check does not prove issuance; use the smoke check above for issuance evidence.
