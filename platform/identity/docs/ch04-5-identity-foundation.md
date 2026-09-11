# CH04.5 - Identity Foundation

CH04.5 defines the base identity model before application-specific SSO bindings are enabled.

The goal is to avoid a single broad admin group and instead create scoped groups that can later be mapped independently to Argo CD, Authentik and CH05 operations WebUIs.

## Scope

CH04.5 owns:

- PlatformInit identity group taxonomy.
- Bootstrap admin membership reconciliation.
- Application-scoped access groups.
- Technical user definitions for later controlled enablement.

CH04.5 does not own:

- Argo CD SSO runtime wiring.
- CH05 operations SSO runtime wiring.
- User password lifecycle.
- Production user onboarding.

Those remain separate lifecycle tasks.

## Files

```text
platform/identity/
├── docs/
│   └── ch04-5-identity-foundation.md
├── groups/
│   └── platforminit-groups.yaml
├── users/
│   └── bootstrap-technical-users.yaml
├── scripts/
│   └── ch04-5-bootstrap-identity-model.sh
└── validate/
    └── ch04-5-validate-identity-model.sh
```

The `.yaml` files are YAML-compatible JSON on purpose. This keeps the bootstrap scripts dependency-free and avoids requiring `yq` or PyYAML on the host.

## Group model

| Group | Scope | Purpose |
|---|---|---|
| `PlatformInit Admins` | platform | Transitional platform admin group. |
| `PlatformInit Operators` | platform | Operational users without global superuser rights. |
| `ArgoCD Admins` | Argo CD | Argo CD admin RBAC group. |
| `ArgoCD Viewers` | Argo CD | Argo CD read-only RBAC group. |
| `Operations Admins` | operations | CH05 operations WebUI admin group. |
| `Operations Viewers` | operations | CH05 operations WebUI viewer group. |
| `Zabbix Admins` | Zabbix | Zabbix operational monitoring admin group. |
| `OpenObserve Admins` | OpenObserve | OpenObserve RCA log admin group. |
| `Authentik Admins` | Authentik | Authentik administration group. |

Only `Authentik Admins` is marked as an Authentik superuser group. Application groups must stay application-scoped.

## Bootstrap membership

By default, CH04.5 attaches the bootstrap Authentik admin user to the initial operational groups:

- `PlatformInit Admins`
- `ArgoCD Admins`
- `Operations Admins`
- `Zabbix Admins`
- `OpenObserve Admins`
- `Authentik Admins`

The username defaults to `akadmin` and can be overridden:

```bash
AUTHENTIK_BOOTSTRAP_ADMIN_USERNAME=akadmin platform/identity/scripts/ch04-5-bootstrap-identity-model.sh
```

## Technical users

Technical users are defined but not created by default. This is intentional until the project defines:

- Password generation and rotation.
- Disablement policy.
- Ownership.
- Audit trail.
- Migration from bootstrap users to real users.

## Runbook

```bash
platform/identity/scripts/ch04-5-bootstrap-identity-model.sh
platform/identity/validate/ch04-5-validate-identity-model.sh
```

## Authentik core deployment contract

The Authentik runtime in namespace `identity` is deployed only by
[`platform/identity/scripts/ch04-5-deploy-authentik-core.sh`](scripts/ch04-5-deploy-authentik-core.sh:1)
and asserted by
[`platform/identity/validate/ch04-5-validate-authentik-core.sh`](validate/ch04-5-validate-authentik-core.sh:1).

### Bounded inputs

| Input | Default | Contract |
|---|---|---|
| `AUTHENTIK_CHART_VERSION` | `2026.2.2` | Exact chart pin only. Ranges and floating selectors are rejected before any mutation. |
| `AUTHENTIK_IMAGE_TAG` | empty (derived) | Optional expectation. When set it must equal the chart `appVersion`; `latest` is rejected. |
| `AUTHENTIK_IMAGE_REPOSITORY` | `ghcr.io/goauthentik/server` | Documented image repository for the deployed Authentik components. |
| `NAMESPACE` | `identity` | Must be a DNS-1123 label. |
| `NAMESPACE_OWNER` | `platforminit` | Expected value of the `app.kubernetes.io/part-of` namespace label. |
| `ALLOW_NAMESPACE_ADOPTION` | `false` | Must be `true` to explicitly adopt a pre-existing unlabeled namespace. |
| `PREFLIGHT_ONLY` | `false` | `true` runs input, secret and namespace preflight plus host tooling preparation and the image-pin render check, then exits before any cluster mutation. |
| `DEPLOY_MODE` / `ISSUER_MODE` | `baseline` / `staging` | Enumerated; unknown values abort. |
| `AUTHENTIK_SECRET_KEY`, `AUTHENTIK_POSTGRESQL_PASSWORD`, `AUTHENTIK_BOOTSTRAP_PASSWORD` | none | Required. Only the env *names* are logged; values are never printed. |
| `AUTHENTIK_BOOTSTRAP_TOKEN` | generated | Reused from the existing `authentik-bootstrap` secret when present, which keeps re-runs stable. |

Image pinning is not guessed from chart keys. The script resolves the `appVersion` of the pinned
chart with `helm show chart`, renders the exact chart/values pair with `helm template`, and refuses
to continue if any rendered image reference is untagged, uses `:latest`, or does not match the
pinned tag.

### Fail-safe preflight

The deployment runs in three ordered phases. The order is the contract: nothing in a later phase
runs until every earlier phase has passed.

1. **Fail-safe preflight (strictly read-only).** In command order: `preflight_inputs` (input
   contract with chart/namespace/domain pinning), `preflight_secret_envs` (required secret env
   names are present and well-formed; values are never logged), `ensure_cluster_ready` (kubeconfig
   exists and `kubectl` can reach the cluster) and `preflight_namespace_ownership` (an existing
   namespace must be owned by `NAMESPACE_OWNER`, otherwise the namespace must be confirmed absent).
   No `apt-get`, no Helm install, no `helm repo` change and no `kubectl` mutation happens in this
   phase.
2. **Bounded preparation and image-pin preflight.** `ensure_runtime_deps`, `ensure_helm`,
   `install_repos`, `resolve_pinned_image_tag` and `preflight_rendered_images`. These steps may
   install host packages, install Helm and change local Helm repository configuration, but they
   never mutate the cluster, and they run only after phase 1 has passed. `PREFLIGHT_ONLY=true`
   stops here.
3. **Cluster mutation (idempotent).** Namespace ensure, secret apply, `helm upgrade --install`,
   deployed image re-verification, public host environment variables, ingress apply and rollout
   wait.

Because no mutable host, Helm or Kubernetes step runs before phase 1, a rejected input, a missing
secret, an unreachable API server or a namespace ownership conflict aborts the run with the host and
the cluster unchanged. Two consequences are deliberate:

- `kubectl` must already be available (installed by CH03) before the deploy script runs, because
  namespace ownership is verified before any tooling is installed.
- a namespace that cannot be *read* aborts the run: an API error is never treated as "namespace
  does not exist", so the script cannot create a namespace it failed to inspect.

Namespace ownership is never forced: an existing namespace labeled with a different
`app.kubernetes.io/part-of` value aborts the run, and an unlabeled namespace is adopted only with
`ALLOW_NAMESPACE_ADOPTION=true`.

The ordering itself is regression-guarded by a static, cluster-free check at the top of
[`platform/identity/validate/ch04-5-validate-authentik-core.sh`](validate/ch04-5-validate-authentik-core.sh:39)
that parses `main()` and fails if any mutable step precedes the secret or namespace preflight.

### Idempotence

Re-running the script with the same inputs and the same chart pin converges on the same state:

- namespace creation is conditional and the ownership label is applied with `--overwrite`;
- the three `authentik-*` secrets are applied through `kubectl apply`, so unchanged values are not
  rewritten as new objects;
- the release is a single `helm upgrade --install` on the pinned chart version, not a second install;
- ingress and certificate are re-applied from the same rendered templates;
- `AUTHENTIK_BOOTSTRAP_TOKEN` is reused from the existing secret instead of being regenerated.

Deploying with a *different* `AUTHENTIK_CHART_VERSION` is an upgrade, not an idempotent re-run, and
must be treated as a change window.

### Operator commands

```bash
# Validate deploy preconditions without mutating the cluster.
PREFLIGHT_ONLY=true platform/identity/scripts/ch04-5-deploy-authentik-core.sh

# Deploy or reconcile the pinned Authentik core.
platform/identity/scripts/ch04-5-deploy-authentik-core.sh

# Assert namespace ownership, secrets, rollouts, routing and pinned images.
platform/identity/validate/ch04-5-validate-authentik-core.sh
```
