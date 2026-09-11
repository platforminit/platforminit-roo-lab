# CH04.5 - Identity Ownership Inventory and Boundary

Task: `P-CH04.5-T01` - Inventory current Authentik foundation.

This document is an audit artifact. It records which identity assets are canonical, which
CH06-named files are deprecated compatibility surface, and who owns what. Nothing in this
document changes runtime behaviour.

## 1. Evidence basis

Read-only inspection of the repository at branch `batch/platform-ch04-5-authentik-inventory`
(base `dev` at `e1de7d3`). No host, cluster, Authentik, DNS, Cloudflare, GitHub secret or GitHub
environment state was read or mutated.

Commands and sources used:

```bash
find platform/identity -type f | sort
diff -u platform/identity/scripts/ch06-orchestrator.sh \
        platform/identity/scripts/ch04-5-deploy-authentik-core.sh
grep -rIn "ch06" .                     # repository-wide reference scan
grep -rIn "remote.sh" .github/workflows/*.yml
grep -n "identity" .github/workflows/build-platform-artifacts.yml
```

No secret values are reproduced here. Only secret and environment variable *names* are listed.

## 2. Canonical ownership

| Concern | Canonical owner | Canonical assets | How it is executed |
|---|---|---|---|
| Authentik runtime (namespace `identity`, server/worker/PostgreSQL) | CH04.5 | `scripts/ch04-5-deploy-authentik-core.sh`, `values/authentik-values.yaml.tpl` | Workflow `04.5 - Deploy Identity Foundation` via remote entrypoint `/tmp/platforminit-run/ch04-5-remote.sh` |
| Authentik public route and TLS | CH04.5 | `ingress/authentik-ingress.yaml`, `ingress/authentik-certificate.yaml` | Rendered and applied by `ch04-5-deploy-authentik-core.sh` (`auth.__BASE_DOMAIN__`, issuer `letsencrypt-<staging\|prod>`) |
| Identity group taxonomy | CH04.5 | `groups/platforminit-groups.yaml` | Reconciled by `scripts/ch04-5-bootstrap-identity-model.sh` against the Authentik API |
| Bootstrap admin membership and technical user definitions | CH04.5 | `users/bootstrap-technical-users.yaml` | Same reconciler; technical users are defined but not created by default |
| Identity model validation | CH04.5 | `validate/ch04-5-validate-identity-model.sh` | Invoked by the `04.5` workflow after bootstrap |
| Authentik core validation | CH04.5 | `validate/ch04-5-validate-authentik-core.sh` | Invoked by the `04.5` workflow |
| Argo CD SSO binding (Authentik OIDC provider -> Argo CD Dex/`argocd-cm`) | CH04.6 | `scripts/ch04-6-enable-argocd-sso.sh`, `validate/ch04-6-validate-argocd-sso.sh`, `integrations/argocd/argocd-authentik-oidc-cm.yaml.tpl`, `integrations/argocd/argocd-authentik-rbac-cm.yaml.tpl` | Workflow `04.6 - Enable Argo CD SSO` |
| CH05 operations WebUI SSO bindings (Zabbix SAML, OpenObserve OIDC, Checkmk trusted-header) | CH05 | `platform/observability/scripts/ch05-3-*` | Workflow `05.3 - Enable Checkmk Trusted-Header SSO`; only the Authentik provider/application side is reconciled here |
| CH06 | Reserved for Security & Compliance v2 | - | No identity ownership. See [`docs/platforminit-rationalization-open-issues.md`](../../../docs/platforminit-rationalization-open-issues.md) (P1: CH06 naming conflict) |

Ownership rules that follow from the table:

1. Authentik is deployed and reconciled by CH04.5 only. CH04.6 and CH05.3 consume the CH04.5
   foundation and must not deploy Authentik themselves.
2. The `identity` namespace, the `auth.<PLATFORM_BASE_DOMAIN>` route, and the
   `authentik-*` secrets belong to CH04.5.
3. Application SSO wiring belongs to the application chapter (CH04.6 for Argo CD, CH05 for the
   operations WebUIs), not to CH04.5.
4. The name `CH06` in this repository must not be read as identity ownership. It is either
   historical identity/Argo CD SSO compatibility naming or the future Security & Compliance v2
   chapter.

## 3. Full CH04.5 asset inventory

| Asset | Role | Status |
|---|---|---|
| `README.md` | Operator entry doc for the identity chapter | Canonical |
| `docs/ch04-5-identity-foundation.md` | CH04.5 scope, group model, technical user policy | Canonical |
| `docs/ch04-6-argocd-sso-runbook.md` | Argo CD SSO runbook | Canonical |
| `docs/ch04-5-identity-ownership-inventory.md` | This inventory and boundary statement | Canonical (new) |
| `docs/ch06-identity-runbook.md` | Historical CH06 identity runbook | Deprecated compatibility - see section 4 |
| `docs/ch06-sso-integration.md` | Historical CH06 SSO note | Deprecated compatibility - see section 4 |
| `groups/platforminit-groups.yaml` | Group taxonomy, YAML-compatible JSON to stay `yq`-free | Canonical |
| `users/bootstrap-technical-users.yaml` | Bootstrap memberships + technical user definitions | Canonical |
| `scripts/ch04-5-deploy-authentik-core.sh` | Authentik core deploy (Helm + secrets + ingress + rollout wait) | Canonical |
| `scripts/ch04-5-bootstrap-identity-model.sh` | Authentik API reconciler for groups and bootstrap membership | Canonical |
| `scripts/ch04-6-enable-argocd-sso.sh` | Argo CD OIDC provider + `argocd-cm`/`argocd-rbac-cm` reconciliation | Canonical |
| `scripts/ch06-deploy.sh` | Legacy entrypoint, `exec`s `ch06-orchestrator.sh` | Deprecated compatibility |
| `scripts/ch06-orchestrator.sh` | Legacy Authentik deploy orchestrator | Deprecated compatibility |
| `validate/ch04-5-validate-authentik-core.sh` | Namespace, secrets, deployments, service, ingress, certificate, pod readiness | Canonical |
| `validate/ch04-5-validate-identity-model.sh` | Group taxonomy and bootstrap membership assertions | Canonical |
| `validate/ch04-6-validate-argocd-sso.sh` | Argo CD SSO assertions | Canonical |
| `validate/ch06-validate-identity.sh` | Legacy Authentik core assertions | Deprecated compatibility |
| `values/authentik-values.yaml.tpl` | Chart values; secrets referenced as file mounts, never inline | Canonical |
| `ingress/authentik-certificate.yaml` | Certificate for `auth.__BASE_DOMAIN__` | Canonical |
| `ingress/authentik-ingress.yaml` | Traefik ingress for `auth.__BASE_DOMAIN__` | Canonical |
| `integrations/argocd/argocd-authentik-oidc-cm.yaml.tpl` | Argo CD Dex OIDC connector template | Canonical |
| `integrations/argocd/argocd-authentik-rbac-cm.yaml.tpl` | Argo CD RBAC mapping template | Canonical |
| `reports/.gitkeep` | Report output directory placeholder | Canonical |

## 4. Deprecated CH06 compatibility surface

### 4.1 In-repo files

| Deprecated asset | Superseded by | Evidence that it is not active |
|---|---|---|
| `scripts/ch06-orchestrator.sh` | `scripts/ch04-5-deploy-authentik-core.sh` | `diff -u` shows the two scripts are functionally identical; only the log prefix (`[CH06]` -> `[CH04.5][AUTHENTIK_CORE]`) and the completion message differ. No workflow references it. |
| `scripts/ch06-deploy.sh` | `scripts/ch04-5-deploy-authentik-core.sh` | Thin `exec` wrapper around `ch06-orchestrator.sh`. No workflow references it. |
| `validate/ch06-validate-identity.sh` | `validate/ch04-5-validate-authentik-core.sh` | Same assertions (namespace, three secrets, server/worker deployment + rollout, service, ingress, certificate, pod readiness, TLS readiness). No workflow references it. |
| `docs/ch06-identity-runbook.md` | `docs/ch04-5-identity-foundation.md` | Declares itself deprecated. No workflow references it. |
| `docs/ch06-sso-integration.md` | `docs/ch04-6-argocd-sso-runbook.md` | Documents the active bindings only; no CH06-specific behaviour. No workflow references it. |

The only repository-wide references to `ch06` are these files themselves, the compatibility
entrypoint name used by the `04.6` workflow, the sudo scope comment in the host baseline, and
`argocd/apps/ch06-identity.yaml`. None of them is an active CH04.5/CH04.6 code path.

### 4.2 Compatibility surface outside the CH04.5 file scope

These are cross-chapter references that were inventoried but deliberately not modified by
`P-CH04.5-T01`:

| Location | Observation | Owner |
|---|---|---|
| `.github/workflows/deploy-04-6-argocd-sso.yml` (render step, scp step, launch step) | The CH04.6 workflow still ships its remote entrypoint as `/tmp/platforminit-run/ch06-remote.sh` and labels it a "compatibility entrypoint". The payload is the CH04.6 script `scripts/ch04-6-enable-argocd-sso.sh`. | CH04.6 workflow |
| `platform/host-baseline/scripts/grant-temporary-sudo.sh` (scopes `identity` and `identity-sso`) | Both `ch06-remote.sh` and `ch04-6-remote.sh` command paths stay sudo-allowed until live hosts refresh grant tooling from the host baseline. | CH01/CH02 host baseline |
| `argocd/apps/ch06-identity.yaml` | Argo CD `Application` named `ch06-identity` with `targetRevision: feat/ch06-identity-sso-foundation` and `path: platform/identity`, `syncPolicy.automated` with prune+selfHeal. The revision is a stale feature branch, which makes this a runtime risk if it is ever applied. | Argo CD platform-services/bootstrap |
| `platform/identity/**` artifact packing in `.github/workflows/build-platform-artifacts.yml` | The identity artifact ships `platform/identity` verbatim, so the deprecated CH06 files are still distributed to hosts even though no workflow invokes them. | Artifact build |

### 4.3 Compatibility invariants

Until the compatibility surface is retired by a tracked task, the following must stay true:

- `ch06-deploy.sh` and `ch06-orchestrator.sh` must not be deleted while any live host still
  exposes a `ch06-remote.sh`-based execution path assumption - deletion must be coordinated with
  the CH01/CH02 sudo scope cleanup.
- The deprecated files must not gain new behaviour. No new Authentik feature may be implemented
  in a `ch06-*` file.
- Any rename of the `04.6` remote entrypoint must keep the compat alias in
  `grant-temporary-sudo.sh` consistent in the same change.
- `argocd/apps/ch06-identity.yaml` must not be applied as-is; its `targetRevision` points at a
  stale feature branch.

## 5. Deliberate non-changes

`P-CH04.5-T01` is an inventory and documentation task. It explicitly did not:

- deploy, upgrade, restart, patch or delete any Authentik, Kubernetes, Traefik, cert-manager or
  Argo CD resource;
- create, rotate or read GitHub secrets, GitHub environments, Authentik API tokens or
  application-local break-glass credentials;
- change DNS or Cloudflare records;
- modify any workflow under `.github/workflows/`;
- modify the deprecated `ch06-*` scripts or validators, so their compatibility behaviour is
  preserved exactly;
- edit `tasks/tracker.json` or generated `tasks/active/**` state (controller-owned).

## 6. Follow-up candidates (not part of this task)

1. Remove or rename the CH06 identity compatibility surface once
   `grant-temporary-sudo.sh` no longer needs the `ch06-remote.sh` path on live hosts.
2. Rename the `04.6` remote entrypoint from `ch06-remote.sh` to `ch04-6-remote.sh` and drop the
   compat sudo scope in the same change.
3. Retire or repoint `argocd/apps/ch06-identity.yaml`, whose `targetRevision` still references
   `feat/ch06-identity-sso-foundation`.
4. Align `docs/roo-lab/context/DEPRECATED_COMPONENTS.md` with any future CH06 identity removal.
