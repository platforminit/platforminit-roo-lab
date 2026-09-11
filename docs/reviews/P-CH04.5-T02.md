# Review: P-CH04.5-T02

## Verdict

**REQUEST_CHANGES**

## Findings

### High — preflight contract is factually incorrect and allows mutation before namespace preflight

The deployment script documents and comments phase 1 as read-only and says it performs “no package” or other mutation, but [`main()`](../../platform/identity/scripts/ch04-5-deploy-authentik-core.sh:322) calls [`ensure_runtime_deps()`](../../platform/identity/scripts/ch04-5-deploy-authentik-core.sh:141), [`ensure_helm()`](../../platform/identity/scripts/ch04-5-deploy-authentik-core.sh:147), and [`install_repos()`](../../platform/identity/scripts/ch04-5-deploy-authentik-core.sh:204) before [`preflight_namespace_ownership()`](../../platform/identity/scripts/ch04-5-deploy-authentik-core.sh:104). `apt-get update`, `apt-get install`, Helm installation, and `helm repo add --force-update` are mutations. Consequently, a foreign or unlabeled namespace can fail only after host package state and the local Helm repository configuration have already changed. The same inaccurate claim is repeated in the deployment contract documentation at [`Fail-safe preflight`](../../platform/identity/docs/ch04-5-identity-foundation.md:119).

This undermines the acceptance criterion “secret and namespace preflight fails safely before mutation” and makes `PREFLIGHT_ONLY=true` non-read-only in practice.

**Required fix:** make the contract precise and enforceable. At minimum, validate required secret env names/values and perform cluster reachability plus namespace ownership before any namespace/secret/release mutation; do not describe host dependency installation or Helm repo setup as read-only. Preferably split dependency/bootstrap setup from cluster preflight, or require the dependencies/repository to exist for `PREFLIGHT_ONLY=true` and ensure the namespace check happens before Helm repo mutation. Add focused tests/evidence for foreign namespace and missing-secret failure ordering using command stubs or an equivalent non-infrastructure harness.

## Acceptance review

- Exact chart input validation and shared values-file usage are present.
- Idempotent namespace/secret/Helm/ingress operations are mostly documented and guarded.
- Shell syntax and `git diff --check` evidence is present.
- The read-only/pre-mutation guarantee is not satisfied as written; live-cluster execution was correctly not performed, but focused stubbed evidence is still needed for this ordering-sensitive contract.

## Scope and safety

The patch remains within the allowed `platform/identity/**` and `docs/**` product scope, with controller-owned task metadata changes only. No secret values or infrastructure mutations were observed during review.
