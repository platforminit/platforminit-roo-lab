# Security, Privacy, and Release Review: P-CH04.5-T04

- **Task:** P-CH04.5-T04 — Define identity groups and technical users contract
- **Reviewer:** `platforminit-owasp-reviewer`
- **Branch:** `batch/platform-ch04-5-identity-model`
- **Base:** `dev` (`7e5fce7`)
- **Review mode:** Independent, read-only, changed-scope review
- **Verdict:** **CLEAR**

## Scope and entry gate

MCP `health` succeeded. Delivery context confirmed controller status `needs_security_review`, stage `security-review`, branch `batch/platform-ch04-5-identity-model`, and exactly five non-state changed paths within the allowed scope. The prior correctness review at [`docs/reviews/P-CH04.5-T04.md`](../reviews/P-CH04.5-T04.md:1) returned `APPROVE` and was used only as acceptance evidence.

Reviewed product paths:

- [`platform/identity/groups/platforminit-groups.yaml`](../../platform/identity/groups/platforminit-groups.yaml:1)
- [`platform/identity/users/bootstrap-technical-users.yaml`](../../platform/identity/users/bootstrap-technical-users.yaml:1)
- [`platform/identity/scripts/ch04-5-bootstrap-identity-model.sh`](../../platform/identity/scripts/ch04-5-bootstrap-identity-model.sh:1)
- [`platform/identity/validate/ch04-5-validate-identity-model-contract.sh`](../../platform/identity/validate/ch04-5-validate-identity-model-contract.sh:1)
- [`platform/identity/docs/ch04-5-identity-model-contract.md`](../../platform/identity/docs/ch04-5-identity-model-contract.md:1)

Controller-owned files under `tasks/` were not edited by this review.

## Findings by required security and release focus

### 1. Secret exposure and privacy — CLEAR

No secret values, API tokens, passwords, private keys, certificates, kubeconfigs, or credential material were found in the five changed product paths. The identity model contains only the credential name `AUTHENTIK_BOOTSTRAP_PASSWORD` and `none-provisioned`; it does not contain a credential value. The bootstrap script reads the Authentik API token from the approved environment/Kubernetes Secret path and passes it in process memory to the API client; it does not print the token. The readiness output prints only the authenticated username.

A targeted secret-like scan reported only the expected variable references `AUTHENTIK_BOOTSTRAP_TOKEN`; it did not identify secret material. The repository-only validator does not access Secret data or external systems.

### 2. Reconciler blast radius, destructive behavior, and privilege escalation — CLEAR

The changed reconciler has a bounded Authentik API write surface:

- `POST` only creates a missing group;
- `PATCH` updates one exact-name group or one exact-username bootstrap membership;
- group updates set the declared `is_superuser` value and ownership attributes;
- membership updates union desired groups with current groups and preserve unrelated memberships;
- there is no `DELETE`, prune, force, user creation, or membership removal path;
- duplicate exact-name matches are a hard stop before a write; and
- technical identities remain `create_by_default: false` and are only logged as documentation.

The one intentionally privileged model entry is `Authentik Admins` with `is_superuser: true`; the validator requires it to be the sole superuser group, identity-platform scoped, and not application scoped. No sudo, Kubernetes write, cloud, DNS, or GitHub mutation path was introduced. The script's Kubernetes calls are namespace/rollout reads and a loopback-bound `port-forward`.

Residual operational risk is limited to the bearer token's existing Authentik API authority: this change does not narrow that pre-existing token scope. The script refuses missing namespace, unhealthy deployment, missing token, invalid model, duplicate managed objects, or missing bootstrap user before reconciliation.

### 3. Command injection and input handling — CLEAR

Model values are parsed as JSON, validated before API access, and sent through Python `urllib` request construction rather than shell interpolation or `eval`. Group and username lookups use exact keys. The local port-forward is bound to `127.0.0.1`; endpoint selection is constrained by the explicit loopback pattern before port-forwarding. No workflow input or shell command execution was added in the changed scope.

### 4. Authentik/OIDC and cross-chapter trust boundary — CLEAR WITH FOLLOW-UP ADVISORY

Ownership, consumer, scope, and single-superuser constraints are explicit and statically validated. Provider templates use a closed four-placeholder inventory, deterministic substitution, and no inlined client secret. The CH04.6 interaction is documented: [`platform/identity/scripts/ch04-6-enable-argocd-sso.sh`](../../platform/identity/scripts/ch04-6-enable-argocd-sso.sh:1) can send `attributes: {}` and clear CH04.5 ownership attributes. This is out of scope for this task and is not a new write path in the five changed files. CH04.5 re-stamps those attributes on a subsequent run, but CH04.6 should be fixed in a separately tracked follow-up to preserve ownership metadata rather than relying on self-healing.

This is an advisory release risk, not a blocker for the reviewed contract: no group privilege is granted by the empty attributes payload itself, and the CH04.5 reconciler does not prune or delete objects.

### 5. TLS, DNS, supply chain, permissions, and environment boundaries — CLEAR

The changed scope does not alter TLS, DNS-01, Cloudflare credentials, GitHub Actions permissions, image references, installers, RBAC manifests, or environment routing. The unchanged ingress/TLS regression validator passed with `pass=54 warn=1 fail=0`; its existing TLS-hardening warning remains assigned to the Traefik exposure contract. No infrastructure workflow or live Authentik, Kubernetes, DNS, Cloudflare, GitHub secret, or GitHub environment operation was run.

### 6. Evidence and artifact leakage — CLEAR

The focused validators and report contain paths, resource names, policy names, and counts only. No secret values were emitted. The temporary port-forward log path is runtime-local and outside the changed product files; the reviewed code does not include its contents in the repository or report. The repository-only validator is static and does not contact a cluster.

### 7. Live validation limitation — REVIEWED RESIDUAL RISK, NOT A BLOCKER

No live Authentik/cluster validation was performed, as required by the task constraints. Offline evidence is strong for contract shape, deterministic rendering, phase ordering, no-delete/no-prune behavior, duplicate refusal, and technical-user creation refusal, but it cannot prove the deployed Authentik API's exact response shapes, token permissions, or runtime authorization behavior. Existing live validation remains required before infrastructure release; this review does not claim runtime proof.

## Evidence collected

- `git status --short` and `git branch --show-current`: expected batch branch, five product paths, controller-owned task state, and the prior review artifact.
- `git diff --check`: exit `0`.
- JSON parsing of both model files: exit `0`.
- `bash -n` for the changed bootstrap and contract validator scripts: exit `0`.
- [`platform/identity/validate/ch04-5-validate-identity-model-contract.sh`](../../platform/identity/validate/ch04-5-validate-identity-model-contract.sh:1): `pass=37 warn=1 fail=0`.
- Unchanged [`platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh`](../../platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh:1): `pass=54 warn=1 fail=0`.
- Focused source review of API methods, phase ordering, duplicate handling, membership merging, secret references, provider placeholder checks, and forbidden-operation assertions.
- No infrastructure workflow or live system mutation was performed.

## Verdict and rationale

**CLEAR.** No security, privacy, destructive-operation, privilege-escalation, secret-exposure, or release-hygiene blocker was found in the changed scope. The implementation keeps technical-user creation disabled, refuses ambiguous managed objects, performs only bounded upsert/PATCH operations, preserves unrelated memberships, and contains no secret material. The CH04.6 empty-attributes behavior and absence of live runtime validation remain documented follow-up/release risks, not silent approvals of those conditions.

## Follow-up risks

1. Track a CH04.6 change to preserve existing CH04.5 ownership attributes instead of sending `attributes: {}`.
2. Before live release, run the existing approved read-only/runtime validation against the target Authentik deployment and verify the bootstrap token has only the intended API authority; do not print token values.
3. Keep the existing Traefik TLS-hardening advisory under the owning exposure contract.
