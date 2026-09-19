# CH04.5 - Identity Groups and Technical Users Contract

Task: `P-CH04.5-T04` - Define identity groups and technical users contract.

This document states the CH04.5 **identity model** as one explicit contract: which groups exist, which
identities are managed by CH04.5, who owns each object, how the provider templates render
deterministically, and why a re-run of the identity bootstrap cannot duplicate or drift a managed
object. It is normative for every CH04.5 change that touches the group taxonomy, the technical
identity definitions, the Authentik reconciler or the Argo CD provider templates.

The document is a contract statement, not an operator action. Nothing here mutates a cluster,
Authentik, Kubernetes, DNS, Cloudflare, a GitHub secret or a GitHub environment.

## 1. The contract in one statement

| Element | Contract value | Artifact |
|---|---|---|
| Group taxonomy | `platforminit.identity.groups.v1` - 9 groups, closed name/slug set, explicit ownership per group | [`platform/identity/groups/platforminit-groups.yaml`](../groups/platforminit-groups.yaml:1) |
| Bootstrap identities and technical users | `platforminit.identity.bootstrap-users.v1` - one break-glass bootstrap admin membership, three documented technical users that are never auto-created | [`platform/identity/users/bootstrap-technical-users.yaml`](../users/bootstrap-technical-users.yaml:1) |
| Reconciler | [`platform/identity/scripts/ch04-5-bootstrap-identity-model.sh`](../scripts/ch04-5-bootstrap-identity-model.sh:1) - sole writer of groups, memberships and managed ownership attributes | [`platform/identity/scripts/ch04-5-bootstrap-identity-model.sh`](../scripts/ch04-5-bootstrap-identity-model.sh:1) |
| Ownership model | `management.managed_by`, `management.contract_version`, `management.attribute_prefix`, plus `owner_chapter`, `owner_role`, `consumer_chapter` on every group and identity | Both model files |
| Reconcile mode | `upsert-no-prune` for groups, `membership-upsert-no-prune` for memberships | Both model files |
| Provider templates | 4-placeholder closed inventory, substituted deterministically by the Argo CD SSO renderer, never containing a secret value | `platform/identity/integrations/argocd/*.tpl` |
| Enforcement | Repository-only validator, no cluster access | [`platform/identity/validate/ch04-5-validate-identity-model-contract.sh`](../validate/ch04-5-validate-identity-model-contract.sh:1) |

The group **name** is the reconciliation identity key and the identity key in every membership list.
A group name is never reused for a different purpose: renaming a group is a contract change that must
also update every membership list, the reconciliation stamp and this document in the same change.

## 2. Explicit ownership

Ownership has two layers and both are mandatory:

1. **Object ownership** - `management.managed_by` names the reconciler that owns the object lifecycle,
   and `management.owner_chapter` names the chapter accountable for it. Both models must agree on
   `managed_by` and `contract_version`; a mismatch makes the reconciler stop before any mutation.
2. **Per-entry ownership** - every group and every identity entry declares:

| Field | Meaning |
|---|---|
| `owner_chapter` | The chapter that owns the definition. CH04.5 owns the identity model and is the only writer of these objects. |
| `owner_role` | The accountable operator role inside that chapter, so an unowned group cannot be added. |
| `consumer_chapter` | The chapter or surface that consumes the group for access decisions (`platform`, `CH04.6`, `CH05`, `identity`). Consumers map the group, they do not redefine it. |

Group ownership table (from the model):

| Group | Scope | Owner | Consumer |
|---|---|---|---|
| `PlatformInit Admins` | `platform` | `CH04.5` / `platform-identity-admins` | `platform` |
| `PlatformInit Operators` | `platform` | `CH04.5` / `platform-operations` | `platform` |
| `ArgoCD Admins` | `application:argocd` | `CH04.5` / `argo-cd-platform` | `CH04.6` |
| `ArgoCD Viewers` | `application:argocd` | `CH04.5` / `argo-cd-readonly` | `CH04.6` |
| `Operations Admins` | `application:operations` | `CH04.5` / `operations-platform` | `CH05` |
| `Operations Viewers` | `application:operations` | `CH04.5` / `operations-readonly` | `CH05` |
| `Zabbix Admins` | `application:zabbix` | `CH04.5` / `zabbix-platform` | `CH05` |
| `OpenObserve Admins` | `application:openobserve` | `CH04.5` / `openobserve-platform` | `CH05` |
| `Authentik Admins` | `identity-platform` | `CH04.5` / `identity-platform-admins` | `identity` |

Superuser rules:

1. `Authentik Admins` is the only Authentik superuser group (`is_superuser: true`) and it must stay in
   the `identity-platform` scope with consumer `identity`.
2. No `application:*` group may be a superuser group. Application access is expressed by group
   membership plus the application's own RBAC mapping, never by Authentik superuser inheritance.

Technical identity rules:

| Identity | Kind | Owner | Policy |
|---|---|---|---|
| `akadmin` (`AUTHENTIK_BOOTSTRAP_ADMIN_USERNAME`) | `break-glass-admin` | `CH04.5` / `identity-platform-admins` | Break-glass only. Credential source is the `AUTHENTIK_BOOTSTRAP_PASSWORD` secret; rotation is operator-managed. |
| `platforminit-automation` | `technical` | `CH04.5` / `platform-automation` | Not created. `create_by_default: false`, `credential_source: none-provisioned`, `rotation_policy: tracked-task-required`. |
| `argocd-bootstrap-admin` | `technical` | `CH04.5` / `argo-cd-platform` | Not created. Retired by the tracked CH04.6 onboarding path. |
| `operations-bootstrap-admin` | `technical` | `CH04.5` / `operations-platform` | Not created. Retired by the tracked CH05 onboarding path. |

Rules that follow:

1. **`create_by_default` must stay `false`.** CH04.5 defines technical users; it never provisions them.
   The reconciler refuses to run if any technical user asks to be created by default, and it never
   creates a user object.
2. **Every creation gate is explicit.** `enablement_gate` names the tracked task that must define
   credential issuance, rotation, disablement and audit trail before an identity may exist.
3. **Only secret and variable *names* appear in the model.** `credential_source` is either an
   environment/secret name or the literal `none-provisioned`. No secret value, token or password is
   ever written into the model, the reconciler output, a report or a commit.
4. **Break-glass stays documented.** The bootstrap admin is a transitional identity and its password
   lifecycle remains an operator procedure, not an automated one.

## 3. Deterministic provider templates

The provider templates are the rendering inputs of the Argo CD SSO binding:

- [`platform/identity/integrations/argocd/argocd-authentik-oidc-cm.yaml.tpl`](../integrations/argocd/argocd-authentik-oidc-cm.yaml.tpl:1)
- [`platform/identity/integrations/argocd/argocd-authentik-rbac-cm.yaml.tpl`](../integrations/argocd/argocd-authentik-rbac-cm.yaml.tpl:1)

Placeholder inventory (closed set):

| Placeholder | Substituted with | Rule |
|---|---|---|
| `__BASE_DOMAIN__` | `BASE_DOMAIN` | Argo CD public URL host. |
| `__AUTHENTIK_OIDC_ISSUER__` | resolved Authentik OIDC issuer URL | Must come from the discovered issuer, never a hardcoded host. |
| `__ARGOCD_OIDC_CLIENT_ID__` | created OIDC provider client id | Non-secret identifier. |
| `__ARGOCD_ADMIN_GROUP__` | `ARGOCD_ADMIN_GROUP` | Must name an existing CH04.5 group; the default is `PlatformInit Admins`. |

Provider template rules:

1. **The placeholder set is closed.** A template may only use placeholders from the table above. The
   validator fails when a template introduces an undocumented placeholder, because an undocumented
   placeholder renders as literal `__TEXT__` in the cluster.
2. **Rendering is a single deterministic substitution pass.** Each placeholder is substituted exactly
   once per template by the renderer's `sed` expression; rendering uses no `eval`, no shell glob
   re-expansion and no randomness. Rendering the same template with the same inputs twice must produce
   byte-identical output.
3. **No secret value is ever inlined in a template.** The OIDC client secret stays a Kubernetes Secret
   reference (`$dex.authentik.clientSecret`) patched into `argocd-secret`; templates carry only
   non-secret identifiers and the secret *reference*.
4. **Group names in templates resolve to CH04.5 groups.** `__ARGOCD_ADMIN_GROUP__` is substituted with
   a name that exists in the group taxonomy, and that group must not be an Authentik superuser group.
5. **A template change is a contract change.** Adding a placeholder, adding a second group mapping or
   changing the issuer/clientscope surface requires updating this document and the validator in the
   same change.

## 4. Deterministic bootstrap behaviour

The reconciler executes exactly three ordered phases in one `main()`:

1. **PHASE 1: read-only identity model contract validation (no mutation).** Both model files are parsed
   and validated: schema, management block, required ownership fields, unique names, unique slugs,
   slug format, the single-superuser rule, technical-user policy, and every group reference. Any
   violation exits with `CONTRACT_VIOLATION` and the API is never touched.
2. **PHASE 2: read-only API state.** The reconciler authenticates, then reads groups and users into
   name-indexed dictionaries with a bounded, deterministic pagination walk
   (`IDENTITY_API_PAGE_SIZE`, default `100`, and `IDENTITY_API_MAX_PAGES`, default `25`).
3. **PHASE 3: idempotent reconciliation (deterministic order, upsert, no prune).** Groups are
   reconciled in **sorted name order**, memberships in sorted membership order with their group lists
   sorted, and technical users are only reported, never created.

Behavioural rules:

1. **Every mutation is a mutation of one object identified by a deterministic key.** Groups are keyed
   by exact `name`, identities by exact `username`. Lookups are exact-match, never "first fuzzy hit".
2. **Deterministic order.** Sorted iteration means the same inputs always produce the same sequence of
   `CREATE`, `RECONCILE`, `UNCHANGED` lines and the same API call order.
3. **Ownership attributes are stamped from the model.** Each reconciled group carries
   `platforminit_managed_by`, `platforminit_contract_version`, `platforminit_owner_chapter`,
   `platforminit_owner_role`, `platforminit_consumer_chapter`, `platforminit_scope`,
   `platforminit_slug` and `platforminit_description`, all derived from the model file - never from
   ad-hoc script constants.
4. **Fail-safe preflight ordering.** The phase order above is the contract: no `POST` or `PATCH` can
   execute before the model validation and the read-only API reads have completed.
5. **No destructive path.** The reconciler never deletes a group, a user or a membership, and it never
   prunes unknown objects. Objects it does not own are left untouched (`no-prune`).
6. **A duplicate managed object is a hard stop, not a repair-by-creation.** If the API already holds
   more than one group with a managed name, or more than one user with a managed username, the
   reconciler fails with the conflicting primary keys instead of reconciling into the ambiguity.
7. **Technical users are never created.** The reconciler only prints the documented identity and its
   owner; creation requires an enabling tracked task.

## 5. Idempotence

Re-running the reconciler with the same model and the same cluster state converges on the same state
and performs no write at all:

- a group that does not exist is `CREATE`d once; a later run finds it by exact name and reports
  `UNCHANGED group` without a `PATCH`;
- a group whose ownership attributes or superuser flag drifted is `RECONCILE`d, and the log names the
  drifted keys, so a repair is explainable without reading the API by hand;
- membership is a set operation: desired group primary keys are unioned into the current set,
  duplicates already present in the membership are collapsed, and unrelated (unmanaged) memberships
  are preserved - a run whose desired and current membership already match issues no `PATCH`;
- membership comparison is normalized and type-stable: primary keys are compared in their normalized
  string form whether the API serializes them as keys, nested objects, integers or strings, so a
  member list is never rewritten only because of its wire representation, while the original value
  type is preserved in the `PATCH` payload;
- the ownership attributes make the managed objects self-describing, so a re-run after an external
  writer cleared them re-stamps them instead of creating a parallel object;
- a run with a **different** `management.contract_version`, a renamed group or a changed membership
  list is a contract change window, not an idempotent re-run, and must be reviewed as such.

Because the reconciler is the sole writer of the taxonomy, "no duplicates" is enforced twice: by the
duplicate stop in phase 3 and by the unique name/slug/usernames rules in phase 1.

## 6. Cross-chapter constraints

| Concern | Owner | Constraint |
|---|---|---|
| Group taxonomy, technical identity definitions, managed ownership attributes | CH04.5 | Only the CH04.5 reconciler writes these objects. Consumers map the groups, they do not redefine them. |
| Argo CD SSO provider/application and the Argo CD RBAC group mapping | CH04.6 | `ARGOCD_ADMIN_GROUP` must name an existing CH04.5 group; the SSO binding must not create, rename or delete CH04.5 groups. |
| CH05 operations WebUI SSO bindings | CH05 | Consumes the `Operations *`, `Zabbix Admins` and `OpenObserve Admins` groups; adds no new platform-wide admin group. |
| Argo CD group claim payload | CH04.6, known advisory | The CH04.6 group reconciliation sends `attributes` as an empty object, which clears CH04.5 managed ownership attributes on an existing group. A re-run of the CH04.5 reconciler re-stamps them, so the identity model self-heals, but the CH04.6 payload must be made attribute-preserving by a follow-up tracked change, which this task does not perform. |

Both consumers keep their own reconciliation and both are outside this contract: this document defines
the shared object model and the ownership of those objects, not the application SSO wiring.

## 7. Enforcement and validation

Repository-only validator (static, deterministic, idempotent, no cluster, Authentik, DNS, Cloudflare or
Secret access):

```bash
bash platform/identity/validate/ch04-5-validate-identity-model-contract.sh
```

It enforces: both model schemas and their management blocks; per-entry ownership fields on every group
and identity; unique names, slugs and usernames; the single-superuser and non-superuser
application-group rules; the technical-user policy (`create_by_default: false`, credential source is a
name only, enablement gate present); every membership and technical-user group reference resolving to a
taxonomy name; the closed provider placeholder inventory, the renderer's substitution per placeholder
and byte-identical repeat renders with no placeholder left unsubstituted; the reconciler's phase order
(read-only contract validation, then read-only API reads, then reconciliation), its deterministic sorted
iteration, its upsert/`UNCHANGED` short-circuit, its duplicate stop and its absence of delete/prune and
technical-user creation paths; the consumer-group consistency between the CH04.6 default admin group and
the taxonomy; and the consistency of this document, the taxonomy table in the foundation document and
the ownership inventory.

Live runtime assertions stay where they already are and are not duplicated here:

```bash
# Cluster read-only assertions: group taxonomy, superuser flag and bootstrap membership.
platform/identity/validate/ch04-5-validate-identity-model.sh
```

Required repository validator for every change in this scope:

```bash
git diff --check
```

## 8. Change control

- Adding, renaming or removing a group requires a model edit, a membership review, a taxonomy-table
  update in this document and in the foundation document, and a `management.contract_version` bump.
- Adding a technical user requires `owner_chapter`, `owner_role`, `purpose`, `enablement_gate` and
  `create_by_default: false`; creation itself requires a separate tracked task.
- Any change to the reconciler must preserve the three-phase order, the exact-name upsert, the
  duplicate stop and the no-prune rule, or be reviewed as a contract change.
- Any change to the reconciliation model is validated with the validator above and `git diff --check`
  before submission.
