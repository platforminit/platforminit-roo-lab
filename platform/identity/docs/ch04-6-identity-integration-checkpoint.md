# CH04.6 — Identity Integration Checkpoint (Argo CD SSO)

Task: `P-CH04.6-T04` (close the CH04.6 identity integration checkpoint).

This is the operator checkpoint for the CH04.6 Argo CD SSO integration. It states who owns what,
which failure modes are already known and how to recover from them, and which CH05 operations
prerequisites depend on a healthy CH04.5/CH04.6 identity chain.

It is a *boundary and navigation* document. The contract detail — provider fields, the strict
redirect allow-list, the Dex connector, the RBAC mapping rules and the secret-key inventory — stays
in the documents listed in section 2. This checkpoint points at them instead of restating them, so
there is exactly one authoritative statement per contract.

## 1. Scope

In scope for this checkpoint:

- the CH04.6 ownership and support boundary;
- the known failure modes of the Argo CD SSO path and their recovery, including break-glass;
- the CH05 prerequisite chain as it points at the current Checkmk operations architecture;
- the focused validation that proves the repository-side invariants.

Out of scope:

- any infrastructure or workflow execution, and any Authentik, Kubernetes, DNS, Cloudflare, GitHub
  secret or GitHub environment mutation;
- re-stating implementation contracts that already have an owner document;
- re-validating CH04.5 or CH05 internals; each chapter proves its own contract.

## 2. Authoritative sources (read these, do not duplicate them)

| Contract | Authoritative document |
|---|---|
| CH04.6 Argo CD SSO implementation, provider contract, Dex connector, RBAC rules, login/logout session contract, break-glass path, recovery notes | [`ch04-6-argocd-sso-runbook.md`](ch04-6-argocd-sso-runbook.md:1) |
| CH04.5 break-glass identities, recovery prerequisites, checkpoint record fields, recovery procedures | [`ch04-5-identity-recovery-and-break-glass.md`](ch04-5-identity-recovery-and-break-glass.md:1) |
| CH04.5 identity model, group taxonomy, managed ownership stamps | [`ch04-5-identity-model-contract.md`](ch04-5-identity-model-contract.md:1) |
| CH04.5 asset-level ownership and deprecated-compatibility inventory | [`ch04-5-identity-ownership-inventory.md`](ch04-5-identity-ownership-inventory.md:1) |
| Desired group taxonomy (single definition source for CH04.6 and CH05) | [`platforminit-groups.yaml`](../groups/platforminit-groups.yaml:1) |
| CH05 current Checkmk operations architecture | [`platform/observability/README.md`](../../observability/README.md:1), [`platform/observability/checkmk/README.md`](../../observability/checkmk/README.md:1) |
| CH05 Checkmk dashboards and Alert Manager landing page | [`docs/ch05-checkmk-operations-dashboards.md`](../../../docs/ch05-checkmk-operations-dashboards.md:1) |
| Prior closed-task evidence for this checkpoint's predecessor | [`docs/reviews/P-CH04.6-T03.md`](../../../docs/reviews/P-CH04.6-T03.md:1), [`docs/security-reviews/P-CH04.6-T03.md`](../../../docs/security-reviews/P-CH04.6-T03.md:1) |

## 3. Ownership and support boundary

### 3.1 Chapter ownership

| Area | Owner | CH04.6 relationship |
|---|---|---|
| Authentik runtime, `identity` namespace, `auth.<PLATFORM_BASE_DOMAIN>` route, `authentik-*` secrets | CH04.5 | consumes read-only |
| Identity group taxonomy, groups, memberships, managed ownership attributes | CH04.5 reconciler [`ch04-5-bootstrap-identity-model.sh`](../scripts/ch04-5-bootstrap-identity-model.sh:1) | resolves the admin group by exact-name lookup only; never writes group state |
| Argo CD SSO binding: Authentik provider/application for Argo CD, `argocd-cm` `dex.config`, `argocd-rbac-cm` mapping, Argo CD OIDC credential secret | CH04.6 | owns |
| Argo CD deployment, ingress and TLS | CH04 (platform services) | consumes |
| Checkmk trusted-header SSO and the operations stack | CH05 | not owned, not validated here |
| `ch06-*` identity files | deprecated compatibility surface, no workflow invokes them | must not be reused as a supported path |

### 3.2 Supported and unsupported surface

Supported:

- SSO login to Argo CD through Authentik, with the Argo CD RBAC admin role derived from one
  CH04.5-owned group;
- the local Argo CD `admin` account as an Authentik-independent break-glass path;
- a repository-only proof of the SSO contract, and a separate, explicitly human-approved live test.

Not supported:

- a direct Argo CD `oidc.config` path — the Dex-backed connector is the only supported path and a
  competing direct-OIDC configuration is treated as drift;
- wildcard, prefix or regex redirect matching;
- CH04.6 creating, renaming, re-attribute-ing or deleting an Authentik group, or acting as a second
  writer of the CH04.5 identity model;
- any claim that repository-only validation proves a live browser login, logout or runtime state.

### 3.3 Boundary rules that must not be re-derived locally

1. The Argo CD admin group is CH04.5 state. A group name change is a CH04.5 contract change, not a
   routine CH04.6 re-run input.
2. Argo CD session invalidation is a deliberate operation (rotating the session signing key ends
   every live session), not part of a routine re-run.
3. Break-glass access is transitional. After using it, reconcile `04.6 - Enable Argo CD SSO` and
   re-run the focused validator instead of hand-editing live objects.

## 4. Known failure modes and recovery

### 4.1 Triage table

| Symptom | Likely cause | Action | Detail in |
|---|---|---|---|
| Browser shows `failed to verify the token` | stale cookies, or a leftover direct-OIDC configuration competing with the Dex connector | clear cookies and site data for both `argocd.<domain>` and `auth.<domain>`; then confirm `dex.config` is present and `oidc.config` is empty | runbook "Token verification recovery note" ([`ch04-6-argocd-sso-runbook.md`](ch04-6-argocd-sso-runbook.md:395)) |
| SSO login succeeds but Argo CD denies sync and shows `role:readonly` | the admin group membership was not converged, or the configured group is not the intended CH04.5 group | reconcile CH04.5, then re-run `04.6 - Enable Argo CD SSO`; verify the admin group binding | runbook RBAC section ([`ch04-6-argocd-sso-runbook.md`](ch04-6-argocd-sso-runbook.md:122)); cross-consumer validator section 5 |
| `argocd-server` enters `CrashLoopBackOff` after an SSO change | malformed SSO configuration blocking the server rollout | use the recovery path that drops `dex.config`/`oidc.config` and clears unhealthy pods, then log in with the local `admin` account | runbook "Emergency recovery note" ([`ch04-6-argocd-sso-runbook.md`](ch04-6-argocd-sso-runbook.md:391)) |
| `04.6` fails closed before writing, naming the CH04.5 remedy | the group is missing, is a superuser group, inherits from a parent, is not declared in the CH04.5 taxonomy, belongs to another consumer, or its name is not RBAC-injection safe | do not work around the gate; select a CH04.5-declared platform group and run `04.5 - Deploy Identity Foundation` first | runbook admin-group contract ([`ch04-6-argocd-sso-runbook.md`](ch04-6-argocd-sso-runbook.md:132)) |
| Focused validator fails closed at the `AUTHENTIK_ROLLOUT` prerequisite in a workspace without `kubectl` | expected fail-closed behaviour, not an SSO defect | use the repository-only mode for repository proof; live proof needs cluster access and explicit human approval | runbook validation section ([`ch04-6-argocd-sso-runbook.md`](ch04-6-argocd-sso-runbook.md:223)) |
| A repeat run reports a changed ownership attribute bag on the consumed group | an unexpected writer touched CH04.5-managed group state | stop, reconcile CH04.5, and investigate the second writer before re-running | CH04.5 model contract, section 6 |
| A rename or stale look-alike group is not removed | CH04.5 is `upsert-no-prune`; nothing is deleted automatically | reconcile CH04.5, verify the canonical slug, then decide on a reviewed manual removal | CH04.5 break-glass doc, section 5D ([`ch04-5-identity-recovery-and-break-glass.md`](ch04-5-identity-recovery-and-break-glass.md:176)) |

### 4.2 Break-glass identities

Credential *sources* are named below; no secret value is ever printed, copied or committed. The full
statement lives in section 1 of the CH04.5 break-glass document
([`ch04-5-identity-recovery-and-break-glass.md`](ch04-5-identity-recovery-and-break-glass.md:14)).

| Path | Identity | Credential source (name only) | Use when |
|---|---|---|---|
| Argo CD administration | local Argo CD `admin` | Argo CD's own local admin secret, held in the operator password store | Authentik/Dex SSO is unavailable but Argo CD must stay operable |
| Authentik platform administration | `akadmin` | `AUTHENTIK_BOOTSTRAP_PASSWORD` in the `identity` namespace | SSO or outpost failure; group and membership repair; API-driven recovery |
| Checkmk operations UI | deterministic `cmkadmin` via the auth-shim | none — derived from an approved Authentik session | normal operations access, not a credential escape hatch |

Rules:

1. Never print, copy or commit a secret value; refer to secret names only.
2. Keep the local Argo CD `admin` account and its password out of this repository and out of workflow
   logs. The validator asserts key presence and never reads a secret value.
3. Do not remove an application-local admin path before the corresponding SSO path has been
   validated.

### 4.3 Recovery ordering and mutation gate

The ordering is CH04.5 first, then CH04.6, then CH05. Both consumers resolve the canonical groups by
lookup and fail closed when a group is missing, so reversing the order produces a confusing failure
instead of a fast one
([`ch04-5-identity-recovery-and-break-glass.md`](ch04-5-identity-recovery-and-break-glass.md:39)).

Any runtime mutation of Authentik, Kubernetes, DNS, Cloudflare, GitHub secrets or GitHub
environments requires explicit human approval. Nothing in this checkpoint authorizes an automated
mutation, and this task executed none.

## 5. CH05 prerequisite chain

The CH05 operations chain consumes the identity foundation; it does not own it. The current Checkmk
operations architecture is described in
[`platform/observability/README.md`](../../observability/README.md:5) and
[`platform/observability/checkmk/README.md`](../../observability/checkmk/README.md:52).

Prerequisite chain, in order:

```text
04.5 - Deploy Identity Foundation        -> CH04.5 owns the Authentik runtime and the group taxonomy
04.6 - Enable Argo CD SSO                -> CH04.6 owns the Argo CD SSO binding
00 - Build Platform Artifacts            -> artifact consumed by the CH05 workflows
05 - Register Operations Stack
05.1 - Reconcile Operations Prerequisites
05.2 - Sync Operations Stack             -> Argo CD syncs the operations-stack manifests
05.3 - Enable Checkmk Trusted-Header SSO -> consumes "PlatformInit Operations" by lookup only
05.5 - Provision Checkmk Operations Model
05.7D - Diagnose Checkmk Agent Discovery
05.7 - Install Checkmk Agent and Discover Services
05.6 - Configure Checkmk Operations Entry Point
05.4 - Validate Operations Stack
05.8D - Diagnose Checkmk Graph Rendering
05.8 - Configure Checkmk Operations Dashboards
05.8B - Clean Checkmk Alert Noise
```

Operator-facing entry points are the consolidated `05 - Operations Monitoring` and
`05.D - Operations Diagnostics` workflows; the granular steps above are their internal building
blocks ([`platform/observability/README.md`](../../observability/README.md:41)).

Identity-chain prerequisites CH05 depends on:

1. CH04.5 is reconciled first. The Checkmk SSO step resolves the canonical
   `PlatformInit Operations` (`platforminit-operations`, `consumer_chapter: CH05`) group by lookup
   and refuses retired operations identity names; it writes no group `POST`/`PATCH`
   ([`platform/observability/checkmk/README.md`](../../observability/checkmk/README.md:52)).
2. CH04.6 is independent of CH05. A healthy Argo CD SSO binding is not a prerequisite for Checkmk
   SSO, and this checkpoint does not extend the CH04.6 validation scope to Checkmk.
3. A missing canonical operations group is a CH04.5 problem, not a CH05 problem: reconcile
   `04.5 - Deploy Identity Foundation` instead of creating a parallel group.
4. The Checkmk proxy provider must be attached to an Authentik proxy outpost; otherwise Traefik
   forwardAuth cannot authenticate `checkmk.<base-domain>`
   ([`platform/observability/checkmk/README.md`](../../observability/checkmk/README.md:117)).
5. The Checkmk Alert Manager landing page and dashboard routes documented for CH05.8 assume the
   stable CH05.4/05.5/05.6/05.7 checkpoint
   ([`docs/ch05-checkmk-operations-dashboards.md`](../../../docs/ch05-checkmk-operations-dashboards.md:18)).

Roadmap successors: `P-CH05-T01` (verify the current Checkmk GitOps runtime and retired-stack
boundary) follows this checkpoint. The retired Zabbix/OpenObserve/Vector references that remain in
older documents are historical; the active CH05 lifecycle is Checkmk-based
([`platform/observability/README.md`](../../observability/README.md:14)).

## 6. Evidence model: repository-only proof versus live proof

| Aspect | Repository-only | Live |
|---|---|---|
| Meaning | proves the reconciler, the rendered templates, the CH04.5 taxonomy and the runbook carry the SSO contract | proves the deployed provider, `argocd-cm`/`argocd-secret`/`argocd-rbac-cm` and a real browser login/logout |
| Access | no cluster, no network, non-mutating | requires cluster access and explicit human approval |
| Limit | never proves live login, logout or runtime state | never proves repository invariants or repeat-run convergence |

A repository-only PASS must never be filed as live SSO evidence. The separation contract is stated in
the runbook ([`ch04-6-argocd-sso-runbook.md`](ch04-6-argocd-sso-runbook.md:376)).

## 7. Focused validation for this checkpoint

Run only these commands. They are read-only, deterministic and repository-scoped.

```bash
# 1. Repository-only SSO contract (no cluster, no network).
bash platform/identity/validate/ch04-6-validate-argocd-sso.sh --static
#    expected: PASS, zero failures

# 2. CH04.5 model / CH04.6 / CH05 cross-consumer agreement.
bash platform/identity/validate/ch04-5-validate-identity-cross-consumer.sh
#    expected: zero fail

# 3. Patch and whitespace hygiene for the changed files.
git diff --check
#    expected: no output, rc 0
```

Do not run repository-wide or other-chapter validation from this checkpoint. The live validator
(`bash platform/identity/validate/ch04-6-validate-argocd-sso.sh`) requires cluster read access and
fails closed without `kubectl`; that failure is expected in a WSL workspace and is not an SSO defect.

Recorded evidence for this checkpoint:

- [`docs/reviews/P-CH04.6-T03.md`](../../../docs/reviews/P-CH04.6-T03.md:5) — reviewer verdict APPROVE.
- [`docs/security-reviews/P-CH04.6-T03.md`](../../../docs/security-reviews/P-CH04.6-T03.md:6) — security verdict CLEAR.
- Predecessor static evidence: 39 controls, 0 failures, with `git diff --check` clean. That evidence
  remains valid for this checkpoint because the validator, the runbook and the reconciler are
  unchanged by it.

## 8. Checkpoint record

The release manager owns the record; this document defines the fields (the same fields as the CH04.5
checkpoint, section 3).

| Field | Value |
|---|---|
| Checkpoint id | `P-CH04.6-T04@batch/platform-ch04-6-checkpoint` |
| Branch | `batch/platform-ch04-6-checkpoint` |
| Base | `dev` @ `3528e49` |
| Deliverable | [`ch04-6-identity-integration-checkpoint.md`](ch04-6-identity-integration-checkpoint.md:1) |
| Validators | `git diff --check`; the repository-only SSO contract and cross-consumer checks in section 7 |
| Evidence paths | `docs/reviews/P-CH04.6-T03.md`, `docs/security-reviews/P-CH04.6-T03.md` |
| Approver | pending review, security review and release |

Do not treat this checkpoint as recorded until the review, security-review and release stages have
their verdicts on record.

## 9. Unresolved risks

- No automated check can observe a browser login or logout. The live SSO test remains a
  human-approved manual step with its own evidence.
- The live `kubectl` branch of the validator remains unobserved in a WSL workspace; only an approved
  `04.6 - Enable Argo CD SSO` run proves the deployed objects.
- [`platform/identity/README.md`](../README.md:86) still describes the retired direct-OIDC secret
  path. That file is outside this checkpoint's allowed files and is a documented follow-up.
- The Argo CD login, redirect and logout origins derive from the Argo CD `data.url`. A base-domain
  change must be applied to the Argo CD configuration, the Authentik provider redirect list and the
  deployment inputs together.
- CH04.5 is `upsert-no-prune`: stale or look-alike groups stay until an operator removes them under
  a reviewed change.
- Checkmk-side failure modes (outpost assignment, forwardAuth service reachability, session/CSRF
  behaviour) are owned and validated by CH05; this checkpoint only records the prerequisite chain.

## 10. Next step

Within this task's lifecycle the next stage is review, then security review, then release; the
release manager records the checkpoint. After the checkpoint closes, the roadmap successor
`P-CH05-T01` becomes runnable.
