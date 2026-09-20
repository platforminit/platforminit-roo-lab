#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# CH04.5 - Cross-consumer identity agreement validation (repository-only)
#
# Task: P-CH04.5-T05 (focused CH04.5 validation and recovery checkpoint)
#
# Proves that the CH04.5 desired identity model
#   platform/identity/groups/platforminit-groups.yaml
# agrees with the active downstream consumers that authenticate against it:
#   - CH04.6 Argo CD (Dex-backed SSO + argocd-rbac-cm admin mapping)
#   - CH05 Checkmk trusted-header SSO binding (operations access group)
# and that retired active identities are rejected:
#   - retired CH05 desired-state groups: Zabbix Admins, OpenObserve Admins
#   - the unsupported generic operations admin/viewer split:
#     Operations Admins, Operations Viewers
#
# Static, deterministic, read-only and idempotent. It never calls kubectl, curl,
# Authentik, Kubernetes, DNS, Cloudflare, GitHub or a Kubernetes Secret, and it
# runs no unrelated full-repository validation. Every finding is aggregated
# before a non-zero exit so one run reports the whole cross-consumer surface.
#
# Fail-closed guarantee: aggregating findings must never be confused with the
# checker not running. The embedded checker invocation is deliberately not
# guarded by `|| true`, so its real exit status is preserved, and a non-zero
# checker exit, an empty checker result or a truncated verdict set is reported as
# a validation failure instead of a silent pass (section 2b).
#
# Scope note: the two consumer scripts are read as evidence only. This validator
# never mutates them; CH04.5 owns the group definitions and the consumers resolve
# them.
#############################################################################

PASS=0
WARN=0
FAIL=0

log()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04.5-cross-consumer] $*"; }
pass() { log "PASS: $*"; PASS=$((PASS + 1)); }
warn() { log "WARN: $*"; WARN=$((WARN + 1)); }
fail() { echo "[$(date -u +%FT%TZ)] [VAL][CH04.5-cross-consumer][FAIL] $*" >&2; FAIL=$((FAIL + 1)); }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

GROUPS_MODEL_REL="platform/identity/groups/platforminit-groups.yaml"
USERS_MODEL_REL="platform/identity/users/bootstrap-technical-users.yaml"
RECONCILER_REL="platform/identity/scripts/ch04-5-bootstrap-identity-model.sh"
ARGOCD_CONSUMER_REL="platform/identity/scripts/ch04-6-enable-argocd-sso.sh"
ARGOCD_RBAC_TPL_REL="platform/identity/integrations/argocd/argocd-authentik-rbac-cm.yaml.tpl"
CHECKMK_CONSUMER_REL="platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh"
CONTRACT_DOC_REL="platform/identity/docs/ch04-5-identity-model-contract.md"

# Minimum number of tab-separated verdict lines the embedded checker emits when it
# runs to completion against readable contract files. Fewer lines means the checker
# never ran or was truncated, which must never be read as a clean result.
MIN_CROSS_CHECKS=18

rel() { printf '%s' "${1#"${ROOT_DIR}/"}"; }

summary_exit() {
  log "CH04.5 cross-consumer validation summary: pass=${PASS} warn=${WARN} fail=${FAIL}"
  if (( FAIL > 0 )); then
    echo "[$(date -u +%FT%TZ)] [VAL][CH04.5-cross-consumer][FAIL] cross-consumer violations: ${FAIL}" >&2
    exit 1
  fi
  log "PASS: CH04.5 desired identity model agrees with the active CH04.6 and CH05 consumers (repository-only, no cluster access)"
}

# ---------------------------------------------------------------------------
# 1. Contract surface exists
# ---------------------------------------------------------------------------
require_file() {
  local label="$1" rel_path="$2"
  if [[ -f "${ROOT_DIR}/${rel_path}" ]]; then
    pass "${label}: ${rel_path} present"
  else
    fail "${label}: missing ${rel_path}"
  fi
}

require_file "GROUPS_MODEL"          "$GROUPS_MODEL_REL"
require_file "USERS_MODEL"           "$USERS_MODEL_REL"
require_file "RECONCILER"            "$RECONCILER_REL"
require_file "ARGOCD_CONSUMER"       "$ARGOCD_CONSUMER_REL"
require_file "ARGOCD_RBAC_TEMPLATE"  "$ARGOCD_RBAC_TPL_REL"
require_file "CHECKMK_CONSUMER"      "$CHECKMK_CONSUMER_REL"
require_file "CONTRACT_DOC"          "$CONTRACT_DOC_REL"

# ---------------------------------------------------------------------------
# 2. Cross-consumer agreement checks
#
# The checker prints tab-separated STATUS/CHECK/DETAIL lines and exits 0 for
# *identity findings* so one run aggregates every finding. That aggregation
# contract covers findings only: the invocation below carries no `|| true`, so an
# interpreter, heredoc or tooling failure keeps its real exit status in cross_rc
# and is handled fail-closed in section 2b.
# ---------------------------------------------------------------------------
cross_rc=0
cross_output="$(
  python3 - "${ROOT_DIR}" \
    "$GROUPS_MODEL_REL" "$USERS_MODEL_REL" "$RECONCILER_REL" \
    "$ARGOCD_CONSUMER_REL" "$ARGOCD_RBAC_TPL_REL" \
    "$CHECKMK_CONSUMER_REL" "$CONTRACT_DOC_REL" <<'PY'
import json
import os
import re
import sys

(
    root,
    groups_rel,
    users_rel,
    reconciler_rel,
    argocd_rel,
    argocd_rbac_rel,
    checkmk_rel,
    contract_rel,
) = sys.argv[1:9]

# Retired active identities that no active consumer may depend on. The first two
# are also declared by the CH05 consumer as RETIRED_OPERATIONS_GROUPS; the last
# two are the unsupported generic operations split documented as retired in the
# CH04.5 identity model contract.
RETIRED_SEED = ["Zabbix Admins", "OpenObserve Admins"]
RETIRED_EXTRA = ["Operations Admins", "Operations Viewers"]

ARGOCD_SCOPE = "application:argocd"
OPERATIONS_SCOPE = "application:operations"
OPERATIONS_CONSUMER = "CH05"
ARGOCD_CONSUMER = "CH04.6"
MANAGED_BY = "ch04-5-bootstrap-identity-model"

# A POST/PATCH on the Authentik group endpoint would make a consumer a parallel
# identity owner. Only GET/lookup consumption is allowed inside CH05.
COMPETING_GROUP_WRITE_RE = re.compile(
    r"(ensure_group\(|"
    r"['\"]POST['\"]\s*,\s*['\"]/api/v3/core/groups/|"
    r"['\"]PATCH['\"][^,]*,\s*f?['\"]/api/v3/core/groups/)"
)


def emit(status, check, detail):
    print(f"{status}\t{check}\t{detail}")


def read(path):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return handle.read()
    except OSError as exc:  # noqa: BLE001 - reported as a finding, never raised
        emit("FAIL", "FILE_READ", f"{path} is unreadable: {exc}")
        return None


def default_of(text, var):
    """Value of a first-line ``VAR="${VAR:-default}"`` declaration."""
    match = re.search(
        r'^' + re.escape(var) + r'="\$\{' + re.escape(var) + r':-([^}]*)\}"',
        text,
        re.MULTILINE,
    )
    return match.group(1).strip() if match else None


groups_text = read(os.path.join(root, groups_rel))
users_text = read(os.path.join(root, users_rel))
reconciler_text = read(os.path.join(root, reconciler_rel))
argocd_text = read(os.path.join(root, argocd_rel))
argocd_rbac_text = read(os.path.join(root, argocd_rbac_rel))
checkmk_text = read(os.path.join(root, checkmk_rel))
contract_text = read(os.path.join(root, contract_rel))

if None in (groups_text, users_text, reconciler_text, argocd_text,
            argocd_rbac_text, checkmk_text, contract_text):
    emit("FAIL", "CONTRACT_SURFACE", "one or more cross-consumer contract files are missing")
    raise SystemExit(0)

try:
    groups_model = json.loads(groups_text)
except ValueError as exc:
    emit("FAIL", "GROUPS_MODEL_JSON", f"{groups_rel} is not parseable JSON: {exc}")
    raise SystemExit(0)

try:
    users_model = json.loads(users_text)
except ValueError as exc:
    emit("FAIL", "USERS_MODEL_JSON", f"{users_rel} is not parseable JSON: {exc}")
    raise SystemExit(0)

groups = groups_model.get("groups") or []
management = groups_model.get("management") or {}
by_name = {str(g.get("name")): g for g in groups if isinstance(g, dict)}
by_slug = {str(g.get("slug")): g for g in groups if isinstance(g, dict)}
model_names = set(by_name)

# --- A. ownership and closed taxonomy -------------------------------------
if management.get("managed_by") == MANAGED_BY and management.get("owner_chapter") == "CH04.5" \
        and management.get("reconcile_mode") == "upsert-no-prune":
    emit("PASS", "MODEL_OWNERSHIP",
         f"{groups_rel} is owned by CH04.5 ({MANAGED_BY}, upsert-no-prune)")
else:
    emit("FAIL", "MODEL_OWNERSHIP",
         f"{groups_rel} ownership/management block does not declare CH04.5 upsert-no-prune ownership")

# --- B. CH04.6 Argo CD consumer agreement ---------------------------------
argocd_default_group = default_of(argocd_text, "ARGOCD_ADMIN_GROUP")
if not argocd_default_group:
    emit("FAIL", "ARGOCD_ADMIN_GROUP_DECLARED",
         f"{argocd_rel} does not declare an ARGOCD_ADMIN_GROUP default")
else:
    emit("PASS", "ARGOCD_ADMIN_GROUP_DECLARED",
         f"CH04.6 resolves its admin group from {argocd_rel} (default {argocd_default_group!r})")
    if argocd_default_group in model_names:
        group = by_name[argocd_default_group]
        if group.get("is_superuser") is False:
            emit("PASS", "ARGOCD_ADMIN_GROUP_AGREES",
                 f"CH04.6 admin group {argocd_default_group!r} resolves to a non-superuser CH04.5 group")
        else:
            emit("FAIL", "ARGOCD_ADMIN_GROUP_AGREES",
                 f"CH04.6 admin group {argocd_default_group!r} is an Authentik superuser group in the CH04.5 model")
    else:
        emit("FAIL", "ARGOCD_ADMIN_GROUP_AGREES",
             f"CH04.6 admin group {argocd_default_group!r} is not a CH04.5 model group; "
             f"declared groups: {sorted(model_names)}")

argocd_consumer_groups = [g for g in groups if g.get("consumer_chapter") == ARGOCD_CONSUMER]
if argocd_consumer_groups and all(
        g.get("scope") == ARGOCD_SCOPE and g.get("is_superuser") is False
        for g in argocd_consumer_groups):
    emit("PASS", "ARGOCD_CONSUMER_GROUPS",
         f"CH04.6 consumer groups {sorted(str(g.get('name')) for g in argocd_consumer_groups)} "
         f"are non-superuser {ARGOCD_SCOPE} groups")
else:
    emit("FAIL", "ARGOCD_CONSUMER_GROUPS",
         f"CH04.6 consumer taxonomy is missing or not non-superuser {ARGOCD_SCOPE}")

rbac_admin_mappings = re.findall(
    r"^\s*g,\s*__ARGOCD_ADMIN_GROUP__,\s*role:admin\s*$", argocd_rbac_text, re.MULTILINE)
if len(rbac_admin_mappings) == 1:
    emit("PASS", "ARGOCD_RBAC_TEMPLATE",
         f"{argocd_rbac_rel} maps exactly one admin group through __ARGOCD_ADMIN_GROUP__")
else:
    emit("FAIL", "ARGOCD_RBAC_TEMPLATE",
         f"{argocd_rbac_rel} must contain exactly one 'g, __ARGOCD_ADMIN_GROUP__, role:admin' mapping "
         f"(found {len(rbac_admin_mappings)})")

if re.search(r's\|__ARGOCD_ADMIN_GROUP__\|\$\{ARGOCD_ADMIN_GROUP\}\|g', argocd_text):
    emit("PASS", "ARGOCD_RBAC_RENDER",
         "CH04.6 renders __ARGOCD_ADMIN_GROUP__ from the resolved ARGOCD_ADMIN_GROUP, not a second literal")
else:
    emit("FAIL", "ARGOCD_RBAC_RENDER",
         f"{argocd_rel} does not substitute __ARGOCD_ADMIN_GROUP__ from ${{ARGOCD_ADMIN_GROUP}}")

retired_in_argocd = sorted(
    n for n in RETIRED_SEED + RETIRED_EXTRA
    if n in argocd_text or n in argocd_rbac_text)
if not retired_in_argocd:
    emit("PASS", "ARGOCD_NO_RETIRED",
         "CH04.6 Argo CD consumer references no retired identity")
else:
    emit("FAIL", "ARGOCD_NO_RETIRED",
         f"CH04.6 Argo CD consumer references retired identities: {retired_in_argocd}")

# --- C. CH05 Checkmk consumer agreement -----------------------------------
canonical_name = default_of(checkmk_text, "CANONICAL_OPERATIONS_GROUP")
canonical_slug = default_of(checkmk_text, "CANONICAL_OPERATIONS_GROUP_SLUG")
retired_default = default_of(checkmk_text, "RETIRED_OPERATIONS_GROUPS")

retired = sorted(set(
    RETIRED_SEED
    + [item.strip() for item in (retired_default or "").split(",") if item.strip()]
    + RETIRED_EXTRA))

if canonical_name and canonical_slug:
    emit("PASS", "CH05_CANONICAL_DECLARED",
         f"CH05 consumes {canonical_name!r} ({canonical_slug}) by lookup")
else:
    emit("FAIL", "CH05_CANONICAL_DECLARED",
         f"{checkmk_rel} does not declare the canonical operations group name and slug")

if canonical_slug and len([g for g in groups if str(g.get("slug")) == canonical_slug]) == 1:
    group = by_slug[canonical_slug]
    problems = []
    if group.get("name") != canonical_name:
        problems.append(f"name is {group.get('name')!r}, expected {canonical_name!r}")
    if group.get("consumer_chapter") != OPERATIONS_CONSUMER:
        problems.append(f"consumer_chapter is {group.get('consumer_chapter')!r}, expected {OPERATIONS_CONSUMER!r}")
    if group.get("owner_chapter") != "CH04.5":
        problems.append(f"owner_chapter is {group.get('owner_chapter')!r}, expected 'CH04.5'")
    if group.get("scope") != OPERATIONS_SCOPE:
        problems.append(f"scope is {group.get('scope')!r}, expected {OPERATIONS_SCOPE!r}")
    if group.get("is_superuser") is not False:
        problems.append("group must not be an Authentik superuser group")
    if problems:
        emit("FAIL", "CH05_CANONICAL_AGREES",
             f"CH04.5 model group {canonical_slug} disagrees with the CH05 consumer: " + "; ".join(problems))
    else:
        emit("PASS", "CH05_CANONICAL_AGREES",
             f"CH04.5 owns {canonical_name!r} ({canonical_slug}) as a non-superuser CH05 {OPERATIONS_SCOPE} group")
else:
    emit("FAIL", "CH05_CANONICAL_AGREES",
         f"expected exactly one CH04.5 model group with slug {canonical_slug!r}")

ops_scope_groups = [g for g in groups if g.get("scope") == OPERATIONS_SCOPE]
if len(ops_scope_groups) == 1:
    emit("PASS", "CH05_SINGLE_OPERATIONS_GROUP",
         "exactly one application:operations group exists, so no Checkmk admin/viewer split is formalized")
else:
    emit("FAIL", "CH05_SINGLE_OPERATIONS_GROUP",
         f"expected exactly one application:operations group, found {len(ops_scope_groups)}")

if "require_group(" in checkmk_text and not COMPETING_GROUP_WRITE_RE.search(checkmk_text):
    emit("PASS", "CH05_LOOKUP_ONLY",
         "CH05 resolves the canonical operations group by lookup and defines no competing group writer")
else:
    emit("FAIL", "CH05_LOOKUP_ONLY",
         "CH05 must resolve the canonical operations group by lookup (require_group) and never create or patch it")

if retired_default and "Refusing to reconcile retired" in checkmk_text:
    emit("PASS", "CH05_RETIRED_GUARD",
         f"CH05 declares its retired-identity guard ({retired_default}) and refuses retired reconciliation")
else:
    emit("FAIL", "CH05_RETIRED_GUARD",
         "CH05 must declare RETIRED_OPERATIONS_GROUPS and refuse retired operations reconciliation")

# Retired names are allowed only inside the declared retired-identity guard, so a
# mention anywhere else means the active SSO path still depends on a retired identity.
stale = []
for lineno, line in enumerate(checkmk_text.splitlines(), 1):
    if re.search(r"zabbix|openobserve", line, re.IGNORECASE) \
            and not re.search(r"RETIRED_OPERATIONS_GROUPS|Refusing to reconcile retired", line):
        stale.append(f"{lineno}: {line.strip()}")
if not stale:
    emit("PASS", "CH05_NO_RETIRED_ACTIVE_DEPENDENCY",
         "CH05 depends on no retired identity outside its declared retired-identity guard")
else:
    emit("FAIL", "CH05_NO_RETIRED_ACTIVE_DEPENDENCY",
         "CH05 depends on retired identities: " + " | ".join(stale[:5]))

# --- D. bootstrap membership agreement ------------------------------------
memberships = users_model.get("bootstrap_memberships") or []
technical_users = users_model.get("technical_users") or []
referenced_membership_groups = []
for membership in memberships:
    referenced_membership_groups.extend(str(g) for g in (membership.get("groups") or []))
for user in technical_users:
    referenced_membership_groups.extend(str(g) for g in (user.get("groups") or []))

unknown_groups = sorted(set(referenced_membership_groups) - model_names)
if not unknown_groups:
    emit("PASS", "BOOTSTRAP_GROUP_REFERENCE",
         f"every bootstrap membership/technical-user group reference resolves to a CH04.5 model group "
         f"({len(referenced_membership_groups)} references)")
else:
    emit("FAIL", "BOOTSTRAP_GROUP_REFERENCE",
         f"bootstrap memberships reference groups that are not in the CH04.5 model: {unknown_groups}")

if canonical_name and canonical_name in referenced_membership_groups:
    emit("PASS", "CH05_APPROVAL_PATH",
         f"the CH05 canonical operations group {canonical_name!r} is granted through a CH04.5 bootstrap membership")
else:
    emit("WARN", "CH05_APPROVAL_PATH",
         f"no bootstrap membership grants the CH05 canonical operations group {canonical_name!r}")

# --- E. retired active identity rejection ---------------------------------
present_retired = sorted(n for n in retired if n in model_names)
if not present_retired:
    emit("PASS", "RETIRED_ABSENT_FROM_MODEL",
         f"no retired identity is an active CH04.5 model group ({len(retired)} retired names checked)")
else:
    emit("FAIL", "RETIRED_ABSENT_FROM_MODEL",
         f"retired identities present as active CH04.5 model groups: {present_retired}")

raw_references = [
    (groups_rel, groups_text),
    (users_rel, users_text),
    (reconciler_rel, reconciler_text),
]
leaks = [f"{rel_path}: {name}" for name in retired for rel_path, text in raw_references if name in text]
if not leaks:
    emit("PASS", "RETIRED_ABSENT_FROM_STATE",
         "the identity model, bootstrap users and reconciler reference no retired identity")
else:
    emit("FAIL", "RETIRED_ABSENT_FROM_STATE",
         "retired identity referenced in active CH04.5 state: " + "; ".join(sorted(leaks)))

undocumented = [name for name in retired if name not in contract_text]
if not undocumented:
    emit("PASS", "RETIRED_DOCUMENTED",
         f"the identity model contract documents all {len(retired)} retired names")
else:
    emit("FAIL", "RETIRED_DOCUMENTED",
         f"the identity model contract does not document retired names: {undocumented}")
PY
)" || cross_rc=$?

if [[ -n "${cross_output}" ]]; then
  while IFS=$'\t' read -r status check detail; do
    [[ -n "${status}" ]] || continue
    case "${status}" in
      PASS) pass "${check}: ${detail}" ;;
      WARN) warn "${check}: ${detail}" ;;
      *)    fail "${check}: ${detail}" ;;
    esac
  done <<<"${cross_output}"
fi

# ---------------------------------------------------------------------------
# 2b. Checker integrity: a checker that did not run is a failure, never a pass
#
# Without this guard an empty or truncated checker result increments no counter
# and summary_exit could still exit 0. A failing checker and a silent or partial
# checker are both reported as failures so cross-consumer validation is genuinely
# fail-closed.
# ---------------------------------------------------------------------------
cross_lines=0
if [[ -n "${cross_output}" ]]; then
  cross_lines="$(printf '%s\n' "${cross_output}" | awk 'NF { count++ } END { print count + 0 }')"
fi

if (( cross_rc != 0 )); then
  fail "CHECKER_EXIT: the embedded cross-consumer checker exited with status ${cross_rc}; failing closed because no aggregation result can be trusted"
elif (( cross_lines == 0 )); then
  fail "CHECKER_EMPTY: the embedded cross-consumer checker produced no verdict lines; failing closed so an empty result never passes"
elif (( cross_lines < MIN_CROSS_CHECKS )); then
  fail "CHECKER_TRUNCATED: the embedded cross-consumer checker produced ${cross_lines} verdict lines, expected at least ${MIN_CROSS_CHECKS}; failing closed"
else
  pass "CHECKER_INTEGRITY: the embedded cross-consumer checker completed with status 0 and ${cross_lines} verdict lines"
fi

# ---------------------------------------------------------------------------
# 3. Repository-only guarantee: this validator performs no runtime access
#
# The runtime tool names are assembled from fragments so this guard does not
# match its own pattern text.
# ---------------------------------------------------------------------------
self_code="$(sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d' "${BASH_SOURCE[0]}")"
runtime_tools=("kube""ctl" "cu""rl")
runtime_tools_found=()
for tool in "${runtime_tools[@]}"; do
  if printf '%s\n' "${self_code}" \
      | grep -Eq "(^|[^A-Za-z0-9_/-])${tool}([^A-Za-z0-9_-]|\$)"; then
    runtime_tools_found+=("${tool}")
  fi
done

if (( ${#runtime_tools_found[@]} == 0 )); then
  pass "REPO_ONLY: this validator performs no cluster, DNS or Cloudflare access"
else
  fail "REPO_ONLY: this validator must not invoke runtime tools: ${runtime_tools_found[*]}"
fi

summary_exit
