# CH04.5 Identity Foundation — Recovery and Break-Glass Checkpoint

Task: `P-CH04.5-T05` (focused CH04.5 validation and recovery checkpoint).

This document is the recovery statement for the CH04.5 identity foundation: which break-glass identities
exist, what must be true before recovery starts, how a recovery checkpoint is recorded, and which
*focused* validation proves the checkpoint. It is the operator-facing counterpart of the repository
contract in [`ch04-5-identity-model-contract.md`](ch04-5-identity-model-contract.md:1).

Consumers covered: CH04.6 Argo CD SSO and CH05 Checkmk trusted-header SSO. The CH04.5 desired identity
model in [`platforminit-groups.yaml`](../groups/platforminit-groups.yaml:1) is the single definition
source for both; CH04.6 and CH05 resolve those groups and never own them.

## 1. Break-glass identities

Only the identities below provide a path into the platform when SSO is broken. Nothing in CH04.5
provisions a new break-glass credential: technical users stay uncreated until a tracked task defines
issuance, rotation, disablement and audit trail (see the `enablement_gate` entries in
[`bootstrap-technical-users.yaml`](../users/bootstrap-technical-users.yaml:31)).

| Break-glass path | Identity | Credential source (name only) | Scope | Use when |
|---|---|---|---|---|
| Authentik platform administration | `akadmin` (`AUTHENTIK_BOOTSTRAP_ADMIN_USERNAME`) | `AUTHENTIK_BOOTSTRAP_PASSWORD` secret in the `identity` namespace | `Authentik Admins` (only superuser group) | SSO or outpost failure; group/membership repair; API-driven recovery |
| Argo CD administration | local Argo CD `admin` | Argo CD's own local admin secret | Argo CD platform | Authentik/Dex SSO is unavailable but Argo CD must stay operable |
| Checkmk WebUI operations | deterministic `cmkadmin` principal | none — derived by the CH05 auth-shim from an approved Authentik session | Checkmk operations UI | Normal operations access; not a credential escape hatch |

Recovery rules that follow:

1. **Never print or copy a secret value** into a report, log, commit, chat or evidence file. Refer to
   secret *names* only.
2. **Break-glass is transitional.** The bootstrap admin membership exists so the platform can be
   repaired; it is not a day-2 operating model.
3. **Application-local recovery stays until SSO is proven.** Do not remove an application-local admin
   path before the corresponding SSO path has been validated
   (see [`ch06-identity-runbook.md`](ch06-identity-runbook.md:44)).
4. **CH04.5 is `upsert-no-prune`.** Reconciling the identity model never deletes a group or membership,
   so recovery is additive by design.

## 2. Recovery prerequisites

Verify all of these before starting any recovery action. Steps 1–5 are repository/read-only; step 6 is
the only mutation gate.

1. **Reviewed checkpoint revision.** Recovery runs from a reviewed revision of
   `batch/platform-ch04-5-validation-recovery` (or the release branch/tag that supersedes it), with a
   clean working tree except controller-owned task state.
2. **Focused static validation clean.** `ch04-5-validate-focused.sh --static` reports
   `passed=3 failed=0` (see section 4).
3. **Cluster read access.** `kubectl` reaches the cluster through `${KUBECONFIG}`
   (default `/etc/rancher/k3s/k3s.yaml`) and the `identity` namespace exists and is owned by
   `platforminit`.
4. **Bootstrap material present.** The `authentik-bootstrap` secret exists in the `identity` namespace
   with the bootstrap token/password keys. Presence is checked by name; values are never displayed.
5. **Consumer ordering.** CH04.5 is reconciled *before* CH04.6 (Argo CD SSO) and CH05.3 (Checkmk
   trusted-header SSO). Both consumers resolve the canonical groups by lookup and fail closed when the
   group is missing, so reversing the order produces a confusing failure instead of a fast one.
6. **Explicit human approval for any mutation.** No recovery step in this document may be executed
   automatically by validation tooling. Runtime mutation of Authentik, Kubernetes, DNS, Cloudflare,
   GitHub secrets or GitHub environments requires explicit human approval.

## 3. Recovery checkpoint record

A *recovery checkpoint* is a reviewed, validated revision that an operator can return to. Record it in
the release evidence (the release manager owns the record; this document defines the fields):

| Field | Meaning |
|---|---|
| Checkpoint id | Task id plus revision, e.g. `P-CH04.5-T05@<short-sha>` or the release tag |
| Branch / tag | Reviewed branch or tag the checkpoint refers to |
| Date (UTC) | When the focused validation evidence was produced |
| Commit | Full commit SHA of the checkpoint |
| Validators | `ch04-5-validate-focused.sh --static` (and `--runtime` when cluster access was available) |
| Evidence paths | Log paths for each validator run, plus the reviewer and security-review reports |
| Approver | Human operator who approved the checkpoint |

Do not fabricate a checkpoint: a checkpoint without recorded validator evidence and a named approver is
not a checkpoint.

## 4. Focused validation for a recovery checkpoint

Run only the focused commands below. They are read-only, deterministic and idempotent, and they perform
no repository-wide or other-chapter validation.

```bash
# 0. Show the closed focused step inventory without executing anything.
bash platform/identity/validate/ch04-5-validate-focused.sh --list

# 1. Repository contract + cross-consumer agreement (no cluster access).
bash platform/identity/validate/ch04-5-validate-focused.sh --static
#    expected: passed=3 failed=0, exit 0

# 2. Runtime health signals (opt-in, read-only; requires cluster read access).
CH04_5_VALIDATE_MODE=runtime bash platform/identity/validate/ch04-5-validate-focused.sh --runtime
#    expected with a reachable dev host: passed=5 failed=0; without cluster access it fails closed
#    with an actionable message and never mutates anything

# 3. CH05 Checkmk consumer boundary, repository-only mode.
CH05_SSO_VALIDATE_MODE=static \
  bash platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh

# 4. Repository whitespace/patch hygiene for the changed files.
git diff --check
```

Capture evidence outside the repository, for example:

```bash
mkdir -p /tmp/platforminit-evidence
bash platform/identity/validate/ch04-5-validate-focused.sh --static \
  > /tmp/platforminit-evidence/P-CH04.5-focused-static.log 2>&1
```

### 4.1 Expected repository contract coverage (`--static`)

| Step | Contract proven |
|---|---|
| `ch04-5-validate-identity-model-contract.sh` | group/technical-user schema, ownership, unique names/slugs, superuser rules, provider-template determinism, reconciler determinism and idempotence, document consistency |
| `ch04-5-validate-authentik-ingress-tls.sh` | single TLS ownership for `auth.<BASE_DOMAIN>`, Ingress/Certificate/issuer agreement, identity bootstrap decoupled from ingress reconciliation |
| `ch04-5-validate-identity-cross-consumer.sh` | the CH04.5 model agrees with the active CH04.6 Argo CD and CH05 Checkmk consumers; retired active identities are rejected |

### 4.2 Expected runtime health signals (`--runtime`)

| Signal | Asserted by |
|---|---|
| identity namespace exists and is owned by `platforminit` | `ch04-5-validate-authentik-core.sh` |
| `authentik-server` rollout healthy; image pinned (no floating tag) | `ch04-5-validate-authentik-core.sh` |
| ingress host `auth.<BASE_DOMAIN>` and the `authentik-tls` secret present | `ch04-5-validate-authentik-core.sh` |
| Authentik bootstrap API token valid (API and break-glass path usable) | `ch04-5-validate-identity-model.sh` |
| runtime groups and memberships match the CH04.5 identity model | `ch04-5-validate-identity-model.sh` |

### 4.3 Cross-consumer agreement and retired identities

`ch04-5-validate-identity-cross-consumer.sh` fails closed when any of these regress:

- the embedded repository checker itself does not complete: a non-zero checker exit, an empty checker
  result, or fewer verdict lines than the checker's complete inventory (18 checks) is reported as
  `CHECKER_EXIT`, `CHECKER_EMPTY` or `CHECKER_TRUNCATED` and fails the run. The checker invocation is
  deliberately not wrapped in `|| true`, so an empty or partial result can never be read as a clean
  cross-consumer result;
- the CH04.6 admin group default no longer resolves to a non-superuser CH04.5 group;
- the `argocd-rbac-cm` template stops mapping exactly one admin group through
  `__ARGOCD_ADMIN_GROUP__`, or CH04.6 stops rendering that placeholder from the resolved group;
- the CH05 canonical operations group name/slug no longer resolves to exactly one non-superuser
  `application:operations` CH04.5 group owned by CH04.5 with consumer CH05;
- CH05 starts creating or patching Authentik groups instead of resolving them, or depends on a retired
  identity outside its declared retired-identity guard;
- a bootstrap membership references a group that is not in the CH04.5 model;
- a retired identity (`Zabbix Admins`, `OpenObserve Admins`, `Operations Admins`,
  `Operations Viewers`) becomes an active model group, a bootstrap membership, or a consumer
  dependency.

## 5. Recovery procedures

### A. Reconcile the identity model (idempotent)

Run `04.5 - Deploy Identity Foundation`
([`deploy-04-5-identity-foundation.yml`](../../../.github/workflows/deploy-04-5-identity-foundation.yml:1)).
The reconciler [`ch04-5-bootstrap-identity-model.sh`](../scripts/ch04-5-bootstrap-identity-model.sh:1)
validates the model, reads current state, then upserts groups and memberships in sorted order and
short-circuits unchanged entries. Re-running is safe and changes nothing when the model is already
converged.

### B. Restore Argo CD SSO

Follow [`ch04-6-argocd-sso-runbook.md`](ch04-6-argocd-sso-runbook.md:5). Keep the local Argo CD `admin`
account as the break-glass path while repairing. The admin group used for RBAC must be a CH04.5 model
group; changing it is a contract change and requires the model to change in the same review.

### C. Restore CH05 Checkmk trusted-header SSO

Run CH04.5 reconciliation first, then the CH05.3 SSO enablement described in
[`platform/observability/checkmk/README.md`](../../observability/checkmk/README.md:52). CH05.3 resolves
`PlatformInit Operations` by lookup and refuses retired operations identities; a missing canonical group
is a CH04.5 problem, not a CH05 problem.

### D. Recover from a stale look-alike group

Because CH04.5 is `upsert-no-prune`, a renamed or stale group with a look-alike slug is *not* removed
automatically, and CH05.3 will hard-fail until the model is reconciled. Recovery is an operator action:
reconcile CH04.5, verify the canonical slug with
`bash platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh`, and only then decide
whether the stale group needs a reviewed manual removal.

### E. Return to a recorded checkpoint

Select the checkpoint recorded in section 3, restore the repository revision, and re-run the focused
validation in section 4 before announcing recovery. Runtime health signals require cluster access;
repository-only validation cannot prove runtime health, so an unreachable host must be reported as
unverified rather than assumed healthy.

## 6. Intentionally out of scope

- No repository-wide validation and no other-chapter validation: the focused entrypoint runs only the
  closed CH04.5 step inventory plus the CH05 Checkmk consumer contract.
- No runtime mutation, no infrastructure workflow run, no Authentik/Kubernetes/DNS/Cloudflare/GitHub
  mutation, and no secret value read, printed or committed.
- Retired stacks (Zabbix, OpenObserve) are not revalidated; only the guarantee that no *active* CH04.5
  or CH04.6/CH05 path depends on them is validated.

## 7. Unresolved risks

- `upsert-no-prune` keeps stale groups and memberships until an operator removes them (section 5D).
- CH04.6 re-applies the non-superuser shape of the group it consumes; the CH04.5 model remains the
  definition source, and a group name outside the model is caught by the focused cross-consumer
  validation rather than by the consumer itself.
- Runtime health signals can only be proven with cluster access; repository-only evidence must not be
  presented as runtime proof.
- The retired-identity guard is intentionally limited to the focused consumer paths; retired-stack
  references elsewhere in the repository are outside this checkpoint's validation scope.
