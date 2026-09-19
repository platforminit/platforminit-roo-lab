# CH04.5 - Authentik Ingress and TLS Contract

Task: `P-CH04.5-T03` - Stabilize Authentik ingress and TLS contract.

This document states the CH04.5 Authentik public route as **one explicit contract**: the hostname, the
`Ingress` resource, the `Certificate` resource and single TLS ownership. It is normative for every
CH04.5 change that touches the public route or its certificate, and it is enforced by a repository-only
validator (section 4).

The document is a contract statement, not an operator action. Nothing written here mutates a cluster,
DNS, Cloudflare, cert-manager or a Kubernetes Secret.

## 1. The contract in one statement

| Element | Contract value | Artifact |
|---|---|---|
| Hostname | `auth.<PLATFORM_BASE_DOMAIN>` (`BASE_DOMAIN`, default `sysadminhomelab.hu`), rendered into the template placeholder `__BASE_DOMAIN__` | [`platform/identity/ingress/authentik-ingress.yaml`](ingress/authentik-ingress.yaml:1), [`platform/identity/ingress/authentik-certificate.yaml`](ingress/authentik-certificate.yaml:1) |
| Ingress resource | kind `Ingress`, `networking.k8s.io/v1`, name `authentik`, namespace `identity`, `ingressClassName: traefik`, Traefik entrypoint `websecure`, rule `auth.<PLATFORM_BASE_DOMAIN>` -> service `authentik-server` port `80`, `spec.tls[0].secretName: authentik-tls` | [`platform/identity/ingress/authentik-ingress.yaml`](ingress/authentik-ingress.yaml:1) |
| Certificate resource | kind `Certificate`, `cert-manager.io/v1`, name `authentik-tls`, namespace `identity`, `secretName: authentik-tls`, `issuerRef.kind: ClusterIssuer`, `issuerRef.name: letsencrypt-<staging\|prod>` (template placeholder `__CLUSTER_ISSUER__`), `dnsNames: [auth.<PLATFORM_BASE_DOMAIN>]` | [`platform/identity/ingress/authentik-certificate.yaml`](ingress/authentik-certificate.yaml:1) |
| TLS owner | cert-manager, via the platform `ClusterIssuer` `letsencrypt-staging` / `letsencrypt-prod` with a Cloudflare `dns01` solver. Issuance authority is cluster-scoped and owned by the platform services layer; CH04.5 only consumes it. | `platform/platform-services/issuers/clusterissuer-letsencrypt-*.yaml`, `platform/cluster/addons/cert-manager/clusterissuer-letsencrypt-cloudflare.yaml` |
| Renderer | [`platform/identity/scripts/ch04-5-deploy-authentik-core.sh`](../scripts/ch04-5-deploy-authentik-core.sh:1) `render_apply_ingress()`: substitutes `__BASE_DOMAIN__` and `__CLUSTER_ISSUER__`, then applies the certificate and the ingress. `ISSUER_MODE` is enumerated (`staging` default, `prod`) so `CLUSTER_ISSUER="letsencrypt-${ISSUER_MODE}"`. | [`platform/identity/scripts/ch04-5-deploy-authentik-core.sh`](../scripts/ch04-5-deploy-authentik-core.sh:1) |

The hostname is one single value that must appear identically in three places: the Ingress rule, the
Ingress `spec.tls[].hosts` entry, and the Certificate `spec.dnsNames` entry. Drift between them is a
contract violation, not a configuration preference.

## 2. Single TLS ownership rules

1. **One TLS object owns the host.** The host is served by exactly one `Ingress` (`authentik`) and its TLS
   material is minted by exactly one `Certificate` (`authentik-tls`) in namespace `identity`. This is a
   repository-wide rule: **any other committed manifest in this repository** that puts the Authentik host in
   an `Ingress` `spec.rules[].host` or `spec.tls[].hosts` entry, or that mints `authentik-tls` for that host,
   breaks the contract even when it uses a different resource name, label set or file location. The Ingress
   must not carry a `cert-manager.io/*` (ingress-shim) annotation: two mechanisms writing the same TLS
   secret is forbidden.
2. **TLS secret stays in the same namespace as the workload.** The Ingress, the Certificate and the
   Authentik workloads are all in `identity`, and `authentik-tls` is referenced only from those two
   manifests. Cross-namespace TLS secret reuse is forbidden - a consumer in another namespace needs its
   own Certificate in its own namespace.
3. **Issuance authority is a cluster-scoped `ClusterIssuer` with Cloudflare `dns01`.** CH04.5 consumes
   `letsencrypt-staging` / `letsencrypt-prod`; it never creates issuers, solver configuration, DNS records,
   or the Cloudflare token. The DNS-01 credential secret (`cloudflare-api-token-secret`) stays in the
   cert-manager namespace and must never be referenced from `platform/identity/**`.
4. **The Certificate does not inline `solvers`.** Solver/issuer policy is a platform-services concern; the
   identity Certificate only names the issuer and the DNS name.
5. **Namespace binding is part of the contract.** Both manifests declare `namespace: identity` and the
   deploy script defaults `NAMESPACE=identity`. Because rule 2 forbids cross-namespace TLS secret reuse, a
   namespace change must move the workload, the Ingress and the Certificate together and is a contract
   change requiring review - not an operator override.
6. **TLS parameters are inherited from Traefik.** No minimum TLS version or TLS option is declared on the
   CH04.5 Ingress today; TLS hardening is owned by the Traefik exposure contract (CH03/CH04), not by this
   route. The validator reports this as an advisory, not a failure.

## 3. Identity-model bootstrap is decoupled from ingress/TLS reconciliation

[`platform/identity/scripts/ch04-5-bootstrap-identity-model.sh`](../scripts/ch04-5-bootstrap-identity-model.sh:1)
reconciles the Authentik **identity model** only: groups from `groups/platforminit-groups.yaml`, bootstrap
admin memberships and technical-user definitions from `users/bootstrap-technical-users.yaml`, applied
through the Authentik API (`/api/v3/core/...`).

Its Kubernetes access is read-only: a namespace existence check, `rollout status deploy/authentik-server`,
a local `port-forward` to the API, and reading the bootstrap API token from the `authentik-bootstrap`
secret. It has no Kubernetes write path, and it has no ingress, certificate or cert-manager code path.

Normative rules:

1. **No route/TLS operations in the bootstrap script.** It must not create, patch, apply, delete, label,
   annotate or scale any Kubernetes object, and it must not mention ingress, certificates, cert-manager,
   ClusterIssuers, DNS-01, TLS secrets or the Traefik `websecure` entrypoint at all.
2. **No identity-model reconciliation in the deploy script.** The deploy script must not call the
   bootstrap script and must not reconcile groups, memberships or technical users.
3. **Ordering is an existence dependency, not a coupling of reconciliation.** The deploy script runs
   first because the bootstrap needs the namespace, the healthy `authentik-server` deployment and the
   bootstrap token. The public route and its certificate are *not* inputs to the identity-model bootstrap.
4. **Failure isolation.** An unresolved or not-yet-`Ready` certificate does not fail the identity-model
   bootstrap, and an identity-model change never rewrites the Ingress or the Certificate. A TLS problem is
   diagnosed as ingress/TLS work; an identity-model problem is diagnosed as bootstrap work.
5. **A re-run is independent.** Re-running either script converges without the other: the identity-model
   bootstrap does not wait for certificate issuance, and `render_apply_ingress()` re-applies the same two
   rendered objects from the same templates.

## 4. Enforcement and validation

Repository-only validator (static, deterministic, idempotent, no cluster, DNS, Cloudflare or Secret
access):

```bash
bash platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh
```

It enforces: the hostname/Ingress/Certificate values of section 1; the single TLS ownership rules of
section 2 (a repository-wide scan proving the host has exactly one committed `Ingress` owner and one
committed `Certificate` owner, matching `authentik-tls` secret name in the Ingress and the Certificate, no
ingress-shim annotation, no inlined `solvers`, no DNS-01 credential under `platform/identity/**`, no
`authentik-tls` manifest reference outside the two ingress manifests, committed Cloudflare `dns01`
ClusterIssuers for every issuer name the deploy script can select); the decoupling rules of section 3; and
the consistency of this document with the committed manifests.

Live runtime assertions stay where they already are and are not duplicated here:

```bash
# Cluster read-only assertions: namespace ownership, secrets, rollouts, ingress host, certificate Ready.
platform/identity/validate/ch04-5-validate-authentik-core.sh
```

## 5. Ownership boundary

Consistent with [`platform/identity/docs/ch04-5-identity-ownership-inventory.md`](ch04-5-identity-ownership-inventory.md:1):

| Concern | Owner | Notes |
|---|---|---|
| Authentik runtime, the `auth.<PLATFORM_BASE_DOMAIN>` route, `authentik-tls` and the `authentik-*` secrets | CH04.5 | This document |
| ClusterIssuers, DNS-01 solver wiring and the Cloudflare credential | CH03/CH04 platform services | Consumed, never re-owned, by CH04.5 |
| Argo CD SSO binding | CH04.6 | Consumes the CH04.5 foundation; does not own the Authentik route/TLS |
| CH05 operations WebUI SSO bindings | CH05 | Consumes the CH04.5 foundation |
| CH06 | Reserved for Security & Compliance v2 | No identity ownership; `ch06-*` identity files are deprecated compatibility surface |

## 6. Change control

- Any edit to the hostname, the Ingress, the Certificate, the issuer name or the TLS secret name must keep
  sections 1 and 2 true and must keep the validator green in the same change.
- The template placeholders `__BASE_DOMAIN__` and `__CLUSTER_ISSUER__` must stay resolvable by
  `render_apply_ingress()`; a manifest that ships an unreplaced placeholder is a deployment failure, not a
  contract violation, and is caught by the deploy preflight.
- Secret values are never reproduced in this document or in the validator. Only resource, secret and
  variable *names* are listed.
