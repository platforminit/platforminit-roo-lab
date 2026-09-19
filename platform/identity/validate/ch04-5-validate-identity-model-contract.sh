#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# CH04.5 - Identity groups and technical users contract validation
# (repository-only)
#
# Task: P-CH04.5-T04. Contract statement:
#   platform/identity/docs/ch04-5-identity-model-contract.md
#
# Static, deterministic and idempotent. It never touches a cluster, Authentik,
# Kubernetes, DNS, Cloudflare, GitHub or a Kubernetes Secret. Every finding is
# aggregated before a non-zero exit so one run reports the whole contract
# surface.
#
# Enforced:
#   1. group taxonomy and identity model contract: schema, management block,
#      per-entry owner_chapter/owner_role/consumer_chapter, unique names, slugs
#      and usernames, single-superuser rule, application groups never
#      superuser, technical user policy
#   2. provider template determinism: closed placeholder inventory, substitution
#      per placeholder, byte-identical repeat renders, no unsubstituted
#      placeholder, no inlined client secret
#   3. reconciler determinism and idempotence: ordered phases, model validation
#      before API reads before reconciliation, sorted upsert, UNCHANGED
#      short-circuit, duplicate stop, no delete/prune path, no technical user
#      creation
#   4. consumer and document consistency: CH04.6 default admin group resolves to
#      a non-superuser taxonomy group, foundation document taxonomy equals the
#      model, ownership inventory attribution, contract document content
#############################################################################

PASS=0
WARN=0
FAIL=0

log()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04.5-identity-model] $*"; }
pass() { log "PASS: $*"; PASS=$((PASS + 1)); }
warn() { log "WARN: $*"; WARN=$((WARN + 1)); }
fail() { echo "[$(date -u +%FT%TZ)] [VAL][CH04.5-identity-model][FAIL] $*" >&2; FAIL=$((FAIL + 1)); }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

GROUPS_FILE="${ROOT_DIR}/platform/identity/groups/platforminit-groups.yaml"
USERS_FILE="${ROOT_DIR}/platform/identity/users/bootstrap-technical-users.yaml"
BOOTSTRAP_SCRIPT="${ROOT_DIR}/platform/identity/scripts/ch04-5-bootstrap-identity-model.sh"
ARGOCD_SSO_SCRIPT="${ROOT_DIR}/platform/identity/scripts/ch04-6-enable-argocd-sso.sh"
CONTRACT_DOC="${ROOT_DIR}/platform/identity/docs/ch04-5-identity-model-contract.md"
FOUNDATION_DOC="${ROOT_DIR}/platform/identity/docs/ch04-5-identity-foundation.md"
INVENTORY_DOC="${ROOT_DIR}/platform/identity/docs/ch04-5-identity-ownership-inventory.md"
TEMPLATES_DIR="${ROOT_DIR}/platform/identity/integrations/argocd"

# Closed provider placeholder inventory. Adding a placeholder is a contract
# change: this list, the contract document and the renderer must change together,
# otherwise the render check below leaves a literal __PLACEHOLDER__ behind.
TEMPLATE_PLACEHOLDERS=(
  '__BASE_DOMAIN__'
  '__AUTHENTIK_OIDC_ISSUER__'
  '__ARGOCD_OIDC_CLIENT_ID__'
  '__ARGOCD_ADMIN_GROUP__'
)

RENDER_WORK_DIR=""
cleanup() {
  if [[ -n "${RENDER_WORK_DIR}" && -d "${RENDER_WORK_DIR}" ]]; then
    rm -rf "${RENDER_WORK_DIR}"
  fi
}
trap cleanup EXIT

rel() { printf '%s' "${1#"${ROOT_DIR}/"}"; }

summary_exit() {
  log "CH04.5 identity model contract validation summary: pass=${PASS} warn=${WARN} fail=${FAIL}"
  if (( FAIL > 0 )); then
    echo "[$(date -u +%FT%TZ)] [VAL][CH04.5-identity-model][FAIL] contract violations: ${FAIL}" >&2
    exit 1
  fi
  log "PASS: CH04.5 identity groups and technical users contract is consistent (repository-only, no cluster access)"
}

# Shell code with comments removed and backslash continuations joined, so a
# token cannot hide behind a comment or a line break.
script_code() {
  local file="$1"
  sed -e 's/[[:space:]]#.*$//' -e '/^[[:space:]]*#/d' -e ':a' -e '/\\$/{N; s/\\\n//; ta}' "$file"
}

# First line number of an exact literal in a file.
line_of() {
  local file="$1" needle="$2"
  grep -nF -- "$needle" "$file" 2>/dev/null | head -n1 | cut -d: -f1 || true
}

require_file() {
  local label="$1" file="$2"
  if [[ -f "$file" ]]; then
    pass "${label}: $(rel "$file") present"
  else
    fail "${label}: missing $(rel "$file")"
  fi
}

# ---------------------------------------------------------------------------
# 1. Contract surface exists
# ---------------------------------------------------------------------------
require_file "CONTRACT_DOC" "$CONTRACT_DOC"
require_file "GROUPS_MODEL" "$GROUPS_FILE"
require_file "USERS_MODEL" "$USERS_FILE"
require_file "RECONCILER" "$BOOTSTRAP_SCRIPT"
require_file "ARGOCD_SSO_RENDERER" "$ARGOCD_SSO_SCRIPT"
require_file "FOUNDATION_DOC" "$FOUNDATION_DOC"
require_file "OWNERSHIP_INVENTORY" "$INVENTORY_DOC"

# ---------------------------------------------------------------------------
# 2. Identity model contract: schema, ownership, uniqueness, policy
#
# The checker always exits 0 and encodes findings as tab-separated
# STATUS/CHECK/DETAIL lines so one run aggregates every violation.
# ---------------------------------------------------------------------------
model_output="$(
  python3 - "${ROOT_DIR}" <<'PY' || true
import json
import os
import re
import sys

root = sys.argv[1]
groups_path = os.path.join(root, "platform/identity/groups/platforminit-groups.yaml")
users_path = os.path.join(root, "platform/identity/users/bootstrap-technical-users.yaml")
argocd_sso_path = os.path.join(root, "platform/identity/scripts/ch04-6-enable-argocd-sso.sh")
foundation_path = os.path.join(root, "platform/identity/docs/ch04-5-identity-foundation.md")

GROUP_SCHEMA = "platforminit.identity.groups.v1"
USERS_SCHEMA = "platforminit.identity.bootstrap-users.v1"
MANAGED_BY = "ch04-5-bootstrap-identity-model"
ATTRIBUTE_PREFIX = "platforminit"
RECONCILE_MODES = {
    "groups": "upsert-no-prune",
    "users": "membership-upsert-no-prune",
}
GROUP_OWNERSHIP_FIELDS = ("owner_chapter", "owner_role", "consumer_chapter")
IDENTITY_OWNERSHIP_FIELDS = (
    "identity_kind",
    "owner_chapter",
    "owner_role",
    "credential_source",
    "rotation_policy",
)
CREDENTIAL_SOURCE_LITERALS = ("none-provisioned",)
SLUG_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
USERNAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
SECRET_NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")


def emit(status, check, detail):
    print(f"{status}\t{check}\t{detail}")


def text(mapping, key):
    value = mapping.get(key)
    return value if isinstance(value, str) and value.strip() else None


def rel(path):
    return os.path.relpath(path, root)


def load(path, label):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except Exception as exc:  # noqa: BLE001 - reported as a finding, never raised
        emit("FAIL", label + "_JSON", f"{rel(path)} is not parseable JSON: {exc}")
        return None


def check_management(model, label, expected_mode):
    management = model.get("management")
    if not isinstance(management, dict):
        emit("FAIL", label + "_MANAGEMENT", "missing the management ownership block")
        return None
    missing = [
        key
        for key in ("managed_by", "reconcile_mode", "attribute_prefix", "owner_chapter", "contract_version")
        if management.get(key) in (None, "")
    ]
    if missing:
        emit("FAIL", label + "_MANAGEMENT", "management block is missing: " + ", ".join(sorted(missing)))
        return None
    problems = []
    if management["managed_by"] != MANAGED_BY:
        problems.append(f"managed_by must be '{MANAGED_BY}' (found '{management['managed_by']}')")
    if management["reconcile_mode"] != expected_mode:
        problems.append(f"reconcile_mode must be '{expected_mode}' (found '{management['reconcile_mode']}')")
    if management["attribute_prefix"] != ATTRIBUTE_PREFIX:
        problems.append(f"attribute_prefix must be '{ATTRIBUTE_PREFIX}' (found '{management['attribute_prefix']}')")
    version = management["contract_version"]
    if not isinstance(version, int) or isinstance(version, bool) or version < 1:
        problems.append("contract_version must be an integer >= 1")
    if problems:
        emit("FAIL", label + "_MANAGEMENT", "; ".join(problems))
        return None
    emit(
        "PASS",
        label + "_MANAGEMENT",
        f"managed_by={management['managed_by']} reconcile_mode={management['reconcile_mode']} contract_version={version}",
    )
    return management


def credential_source_problem(label, value):
    if value in CREDENTIAL_SOURCE_LITERALS:
        return None
    if isinstance(value, str) and SECRET_NAME_RE.match(value):
        return None
    return f"{label}.credential_source={value!r} is neither a NAME_ONLY credential reference nor 'none-provisioned'"


def group_reference_problems(label, entry, known_groups):
    referenced = entry.get("groups")
    if not isinstance(referenced, list) or not referenced:
        return [label + ".groups must be a non-empty list"]
    return [f"{label}.groups -> {name}" for name in referenced if name not in known_groups]


groups_model = load(groups_path, "GROUPS_MODEL")
users_model = load(users_path, "USERS_MODEL")
if groups_model is None or users_model is None:
    sys.exit(0)

if groups_model.get("schema") != GROUP_SCHEMA:
    emit("FAIL", "GROUPS_SCHEMA", f"schema must be '{GROUP_SCHEMA}'")
else:
    emit("PASS", "GROUPS_SCHEMA", f"schema is '{GROUP_SCHEMA}'")

if users_model.get("schema") != USERS_SCHEMA:
    emit("FAIL", "USERS_SCHEMA", f"schema must be '{USERS_SCHEMA}'")
else:
    emit("PASS", "USERS_SCHEMA", f"schema is '{USERS_SCHEMA}'")

groups_management = check_management(groups_model, "GROUPS_MODEL", RECONCILE_MODES["groups"])
users_management = check_management(users_model, "USERS_MODEL", RECONCILE_MODES["users"])
if groups_management and users_management:
    if groups_management["contract_version"] != users_management["contract_version"]:
        emit("FAIL", "MODEL_CONTRACT_VERSION_MATCH", "both models must declare the same contract_version")
    elif groups_management["managed_by"] != users_management["managed_by"]:
        emit("FAIL", "MODEL_MANAGED_BY_MATCH", "both models must declare the same managed_by")
    else:
        emit("PASS", "MODEL_MANAGEMENT_MATCH", "both models agree on managed_by and contract_version")

groups = groups_model.get("groups")
if not isinstance(groups, list) or not groups:
    emit("FAIL", "GROUP_TAXONOMY", "groups must be a non-empty list")
    groups = []

names = []
slugs = []
ownership_problems = []
superusers = []
application_superusers = []
for group in groups:
    if not isinstance(group, dict):
        emit("FAIL", "GROUP_ENTRY_SHAPE", "every group entry must be a JSON object")
        continue
    name = text(group, "name") or "<unnamed>"
    names.append(group.get("name"))
    slugs.append(group.get("slug"))
    for field in GROUP_OWNERSHIP_FIELDS + ("description", "scope"):
        if not text(group, field):
            ownership_problems.append(f"{name}.{field}")
    if not isinstance(group.get("is_superuser"), bool):
        ownership_problems.append(f"{name}.is_superuser")
    slug = group.get("slug")
    if not isinstance(slug, str) or not SLUG_RE.match(slug):
        ownership_problems.append(f"{name}.slug={slug!r}")
    if group.get("is_superuser") is True:
        superusers.append(group)
        if str(group.get("scope", "")).startswith("application:"):
            application_superusers.append(name)

if not groups:
    emit("FAIL", "GROUP_OWNERSHIP", "no group could be inspected")
elif ownership_problems:
    emit("FAIL", "GROUP_OWNERSHIP", "invalid ownership/slug/superuser fields: " + ", ".join(sorted(ownership_problems)))
else:
    emit(
        "PASS",
        "GROUP_OWNERSHIP",
        f"all {len(groups)} groups declare owner_chapter/owner_role/consumer_chapter, scope, description, slug and boolean is_superuser",
    )

name_duplicates = sorted({name for name in names if name is not None and names.count(name) > 1})
if name_duplicates:
    emit("FAIL", "GROUP_NAME_UNIQUE", "duplicate group names: " + ", ".join(name_duplicates))
else:
    emit("PASS", "GROUP_NAME_UNIQUE", f"{len(names)} unique group names")

slug_duplicates = sorted({slug for slug in slugs if slug is not None and slugs.count(slug) > 1})
if slug_duplicates:
    emit("FAIL", "GROUP_SLUG_UNIQUE", "duplicate group slugs: " + ", ".join(slug_duplicates))
else:
    emit("PASS", "GROUP_SLUG_UNIQUE", f"{len(slugs)} unique group slugs")

if len(superusers) != 1:
    emit("FAIL", "GROUP_SUPERUSER_SINGLE", f"exactly one Authentik superuser group is required, found {len(superusers)}")
elif str(superusers[0].get("scope")) != "identity-platform" or superusers[0].get("consumer_chapter") != "identity":
    emit("FAIL", "GROUP_SUPERUSER_SCOPE", "the superuser group must stay in the identity-platform scope with consumer 'identity'")
else:
    emit("PASS", "GROUP_SUPERUSER_SINGLE", f"single superuser group: {superusers[0].get('name')}")

if application_superusers:
    emit("FAIL", "GROUP_APPLICATION_NOT_SUPERUSER", "application-scoped superuser groups: " + ", ".join(application_superusers))
else:
    emit("PASS", "GROUP_APPLICATION_NOT_SUPERUSER", "no application-scoped group is an Authentik superuser group")

known_group_names = {group.get("name") for group in groups if isinstance(group, dict)}
reference_problems = []

memberships = users_model.get("bootstrap_memberships")
if not isinstance(memberships, list) or not memberships:
    emit("FAIL", "BOOTSTRAP_MEMBERSHIP_ENTRIES", "bootstrap_memberships must be a non-empty list")
    memberships = []

membership_problems = []
bootstrap_usernames = set()
for membership in memberships:
    if not isinstance(membership, dict):
        membership_problems.append("<non-object membership>")
        continue
    label = f"bootstrap membership '{text(membership, 'default_username') or '<unnamed>'}'"
    bootstrap_usernames.add(membership.get("default_username"))
    for field in IDENTITY_OWNERSHIP_FIELDS:
        if not text(membership, field):
            membership_problems.append(f"{label}.{field}")
    source_problem = credential_source_problem(label, membership.get("credential_source"))
    if source_problem:
        membership_problems.append(source_problem)
    reference_problems.extend(group_reference_problems(label, membership, known_group_names))

if membership_problems:
    emit("FAIL", "BOOTSTRAP_MEMBERSHIP_OWNERSHIP", "; ".join(sorted(set(membership_problems))))
elif memberships:
    emit("PASS", "BOOTSTRAP_MEMBERSHIP_OWNERSHIP", f"all {len(memberships)} bootstrap membership(s) declare identity ownership and credential policy")

technical_users = users_model.get("technical_users")
if not isinstance(technical_users, list):
    emit("FAIL", "TECHNICAL_USER_ENTRIES", "technical_users must be a list")
    technical_users = []

technical_problems = []
creation_enabled = []
seen_usernames = set()
for user in technical_users:
    if not isinstance(user, dict):
        technical_problems.append("<non-object technical user>")
        continue
    username = text(user, "username") or "<unnamed>"
    label = f"technical user '{username}'"
    for field in IDENTITY_OWNERSHIP_FIELDS + ("display_name", "purpose", "enablement_gate"):
        if not text(user, field):
            technical_problems.append(f"{label}.{field}")
    if not isinstance(user.get("create_by_default"), bool):
        technical_problems.append(f"{label}.create_by_default must be a boolean")
    elif user["create_by_default"]:
        creation_enabled.append(username)
    if not USERNAME_RE.match(username) and username != "<unnamed>":
        technical_problems.append(f"{label}.username={username!r} is not a lowercase account name")
    if username in bootstrap_usernames:
        technical_problems.append(f"{label} collides with a bootstrap membership username")
    if username in seen_usernames:
        technical_problems.append(f"{label} is defined more than once")
    seen_usernames.add(username)
    source_problem = credential_source_problem(label, user.get("credential_source"))
    if source_problem:
        technical_problems.append(source_problem)
    reference_problems.extend(group_reference_problems(label, user, known_group_names))

if technical_problems:
    emit("FAIL", "TECHNICAL_USER_OWNERSHIP", "; ".join(sorted(set(technical_problems))))
elif technical_users:
    emit(
        "PASS",
        "TECHNICAL_USER_OWNERSHIP",
        f"all {len(technical_users)} technical users declare ownership, credential policy and an enablement gate",
    )

if creation_enabled:
    emit("FAIL", "TECHNICAL_USER_CREATION_POLICY", "create_by_default must stay false for: " + ", ".join(creation_enabled))
else:
    emit("PASS", "TECHNICAL_USER_CREATION_POLICY", "no technical user is created by default")

if isinstance(users_management, dict) and users_management.get("technical_user_creation") != "disabled":
    emit("FAIL", "TECHNICAL_USER_CREATION_GATE", "management.technical_user_creation must stay 'disabled'")
else:
    emit("PASS", "TECHNICAL_USER_CREATION_GATE", "technical user creation stays disabled in the model contract")

if reference_problems:
    emit("FAIL", "MODEL_GROUP_REFERENCES", "unresolved group references: " + ", ".join(sorted(set(reference_problems))))
else:
    emit("PASS", "MODEL_GROUP_REFERENCES", "every membership and technical user group reference resolves to a taxonomy group")

argocd_source = ""
try:
    with open(argocd_sso_path, "r", encoding="utf-8") as handle:
        argocd_source = handle.read()
except OSError:
    argocd_source = ""

default_match = re.search(r'ARGOCD_ADMIN_GROUP="\$\{ARGOCD_ADMIN_GROUP:-([^}]*)\}"', argocd_source)
if not default_match:
    emit("FAIL", "CONSUMER_ARGOCD_ADMIN_GROUP", "could not resolve the ARGOCD_ADMIN_GROUP default from the CH04.6 script")
else:
    default_group = default_match.group(1)
    taxonomy_group = next((group for group in groups if group.get("name") == default_group), None)
    if taxonomy_group is None:
        emit("FAIL", "CONSUMER_ARGOCD_ADMIN_GROUP", f"CH04.6 default admin group '{default_group}' is not in the CH04.5 taxonomy")
    elif taxonomy_group.get("is_superuser") is True:
        emit("FAIL", "CONSUMER_ARGOCD_ADMIN_GROUP", f"CH04.6 default admin group '{default_group}' is an Authentik superuser group")
    else:
        emit(
            "PASS",
            "CONSUMER_ARGOCD_ADMIN_GROUP",
            f"CH04.6 default admin group '{default_group}' resolves to a non-superuser CH04.5 group",
        )

try:
    with open(foundation_path, "r", encoding="utf-8") as handle:
        foundation_text = handle.read()
except OSError:
    foundation_text = ""

section = re.search(r"## Group model\n(.*?)\n## ", foundation_text, re.S)
documented_names = sorted(set(re.findall(r"^\|\s*`([^`]+)`\s*\|", section.group(1), re.M))) if section else []
model_names = sorted(name for name in known_group_names if isinstance(name, str))
if not section:
    emit("FAIL", "FOUNDATION_DOC_TAXONOMY", "could not locate the 'Group model' section in the foundation document")
elif documented_names == model_names:
    emit("PASS", "FOUNDATION_DOC_TAXONOMY", f"foundation document taxonomy matches the model ({len(model_names)} groups)")
else:
    emit("FAIL", "FOUNDATION_DOC_TAXONOMY", f"documented={documented_names} model={model_names}")
PY
)"

if [[ -z "${model_output//$'\n'/}" ]]; then
  fail "MODEL_CONTRACT_CHECKS: the model contract checker produced no findings; treat as a validator failure"
else
  while IFS=$'\t' read -r status check detail; do
    [[ -n "${status:-}" ]] || continue
    case "$status" in
      PASS) pass "${check}: ${detail}" ;;
      WARN) warn "${check}: ${detail}" ;;
      FAIL) fail "${check}: ${detail}" ;;
      *)    fail "MODEL_CONTRACT_CHECKS: unknown status '${status}' for ${check}" ;;
    esac
  done <<< "${model_output}"
fi

# ---------------------------------------------------------------------------
# 3. Provider template determinism
# ---------------------------------------------------------------------------
if [[ -d "$TEMPLATES_DIR" ]]; then
  actual_placeholders="$(grep -ohE '__[A-Z0-9_]+__' "${TEMPLATES_DIR}"/*.tpl 2>/dev/null | LC_ALL=C sort -u || true)"
  declared_placeholders="$(printf '%s\n' "${TEMPLATE_PLACEHOLDERS[@]}" | LC_ALL=C sort -u)"
  if [[ -n "$actual_placeholders" && "$actual_placeholders" == "$declared_placeholders" ]]; then
    pass "TEMPLATE_PLACEHOLDER_INVENTORY: the closed placeholder set is exactly the ${#TEMPLATE_PLACEHOLDERS[@]} documented placeholders"
  else
    fail "TEMPLATE_PLACEHOLDER_INVENTORY: declared=[$(printf '%s' "$declared_placeholders" | tr '\n' ' ')] actual=[$(printf '%s' "$actual_placeholders" | tr '\n' ' ')]"
  fi
else
  fail "TEMPLATE_PLACEHOLDER_INVENTORY: missing template directory $(rel "$TEMPLATES_DIR")"
fi

missing_doc_placeholders=""
for placeholder in "${TEMPLATE_PLACEHOLDERS[@]}"; do
  grep -qF -- "$placeholder" "$CONTRACT_DOC" || missing_doc_placeholders="${missing_doc_placeholders} ${placeholder}"
done
if [[ -z "${missing_doc_placeholders// /}" ]]; then
  pass "TEMPLATE_PLACEHOLDERS_DOCUMENTED: every placeholder of the closed set is documented in the contract"
else
  fail "TEMPLATE_PLACEHOLDERS_DOCUMENTED: contract document is missing placeholders:${missing_doc_placeholders}"
fi

missing_substitutions=""
for placeholder in "${TEMPLATE_PLACEHOLDERS[@]}"; do
  grep -qF -- "s|${placeholder}|" "$ARGOCD_SSO_SCRIPT" || missing_substitutions="${missing_substitutions} ${placeholder}"
done
if [[ -z "${missing_substitutions// /}" ]]; then
  pass "TEMPLATE_RENDER_SUBSTITUTION: the renderer provides a substitution for every documented placeholder"
else
  fail "TEMPLATE_RENDER_SUBSTITUTION: no substitution found for:${missing_substitutions}"
fi

RENDER_WORK_DIR="$(mktemp -d)"
render_template() {
  local template="$1" destination="$2"
  sed \
    -e "s|__BASE_DOMAIN__|contract-test.example.invalid|g" \
    -e "s|__AUTHENTIK_OIDC_ISSUER__|https://auth.contract-test.example.invalid/application/o/argocd/|g" \
    -e "s|__ARGOCD_OIDC_CLIENT_ID__|contract-test-client-id|g" \
    -e "s|__ARGOCD_ADMIN_GROUP__|Contract Test Group|g" \
    "$template" > "$destination"
}

template_issues=""
template_count=0
for template in "${TEMPLATES_DIR}"/*.tpl; do
  [[ -f "$template" ]] || continue
  template_count=$((template_count + 1))
  base="$(basename "$template")"
  render_template "$template" "${RENDER_WORK_DIR}/${base}.first"
  render_template "$template" "${RENDER_WORK_DIR}/${base}.second"
  if ! cmp -s "${RENDER_WORK_DIR}/${base}.first" "${RENDER_WORK_DIR}/${base}.second"; then
    template_issues="${template_issues} ${base}:repeat-render-diff"
  fi
  leftover="$(grep -oE '__[A-Z0-9_]+__' "${RENDER_WORK_DIR}/${base}.first" | LC_ALL=C sort -u | tr '\n' ',' || true)"
  if [[ -n "${leftover%,}" ]]; then
    template_issues="${template_issues} ${base}:unsubstituted=${leftover%,}"
  fi
  if grep -qE 'clientSecret:[[:space:]]*[^$[:space:]]' "${RENDER_WORK_DIR}/${base}.first"; then
    template_issues="${template_issues} ${base}:inlined-client-secret"
  fi
done

if [[ "$template_count" -eq 0 ]]; then
  fail "TEMPLATE_RENDER_DETERMINISM: no provider template was rendered"
elif [[ -z "${template_issues// /}" ]]; then
  pass "TEMPLATE_RENDER_DETERMINISM: ${template_count} provider template(s) render byte-identically twice with no unsubstituted placeholder and no inlined client secret"
else
  fail "TEMPLATE_RENDER_DETERMINISM:${template_issues}"
fi

# ---------------------------------------------------------------------------
# 4. Reconciler determinism, idempotence and safety
# ---------------------------------------------------------------------------
phase1_line="$(line_of "$BOOTSTRAP_SCRIPT" '# --- PHASE 1: read-only identity model contract validation (no mutation) ---')"
phase2_line="$(line_of "$BOOTSTRAP_SCRIPT" '# --- PHASE 2: read-only Authentik API state (no mutation) ---')"
phase3_line="$(line_of "$BOOTSTRAP_SCRIPT" '# --- PHASE 3: idempotent reconciliation (deterministic order, upsert, no prune) ---')"
if [[ -n "$phase1_line" && -n "$phase2_line" && -n "$phase3_line" \
      && "$phase1_line" -lt "$phase2_line" && "$phase2_line" -lt "$phase3_line" ]]; then
  pass "BOOTSTRAP_PHASE_MARKERS: phases are declared in order (${phase1_line} < ${phase2_line} < ${phase3_line})"
else
  fail "BOOTSTRAP_PHASE_MARKERS: expected ordered phase markers, got phase1=${phase1_line:-none} phase2=${phase2_line:-none} phase3=${phase3_line:-none}"
fi

validate_call_line="$(line_of "$BOOTSTRAP_SCRIPT" 'validate_groups_model(groups_model)')"
auth_call_line="$(line_of "$BOOTSTRAP_SCRIPT" 'request("GET", "/api/v3/core/users/me/")')"
read_state_line="$(line_of "$BOOTSTRAP_SCRIPT" 'index_by_name(list_pages("/api/v3/core/groups/"), "name")')"
reconcile_call_line="$(line_of "$BOOTSTRAP_SCRIPT" 'ensure_group(group, groups_management, groups_by_name)')"
if [[ -n "$validate_call_line" && -n "$auth_call_line" && -n "$read_state_line" && -n "$reconcile_call_line" \
      && "$validate_call_line" -lt "$auth_call_line" && "$auth_call_line" -lt "$read_state_line" \
      && "$read_state_line" -lt "$reconcile_call_line" ]]; then
  pass "BOOTSTRAP_EXECUTION_ORDER: contract validation (${validate_call_line}) < read-only API reads (${auth_call_line}, ${read_state_line}) < reconciliation (${reconcile_call_line})"
else
  fail "BOOTSTRAP_EXECUTION_ORDER: expected model validation before API reads before reconciliation, got ${validate_call_line:-none}/${auth_call_line:-none}/${read_state_line:-none}/${reconcile_call_line:-none}"
fi

missing_reconcile_tokens=""
required_reconcile_tokens=(
  'GROUP_SCHEMA'
  'USERS_SCHEMA'
  'SLUG_RE'
  'CONTRACT_VIOLATION'
  'sorted(groups_model["groups"], key='
  'sorted(users_model["technical_users"], key='
  'sorted(membership["groups"])'
  'sorted(users_model["bootstrap_memberships"], key='
  'api_max_pages'
  'group_pk_map('
  'sorted(set('
  'unique_match('
  'managed_attributes(group, management)'
  'f"{prefix}_managed_by"'
  'f"{prefix}_contract_version"'
  'f"{prefix}_owner_chapter"'
  'f"{prefix}_owner_role"'
  'f"{prefix}_consumer_chapter"'
  'UNCHANGED group:'
  'UNCHANGED membership:'
  'RECONCILE group:'
  'RECONCILE membership:'
  'duplicate '
  'must not auto-create technical identities'
)
for token in "${required_reconcile_tokens[@]}"; do
  grep -qF -- "$token" "$BOOTSTRAP_SCRIPT" || missing_reconcile_tokens="${missing_reconcile_tokens} '${token}'"
done
if [[ -z "${missing_reconcile_tokens// /}" ]]; then
  pass "BOOTSTRAP_RECONCILER_CONTRACT: model guard, deterministic sorted upsert, unchanged short-circuit, duplicate stop and ownership stamps are present"
else
  fail "BOOTSTRAP_RECONCILER_CONTRACT: reconciler is missing:${missing_reconcile_tokens}"
fi

# `grep -c` style capture, never `grep -q` inside a pipeline: with `pipefail` a
# `-q` grep that exits on its first match would turn a real hit into a
# non-zero pipeline status and silently pass a negative assertion.
delete_hits="$(script_code "$BOOTSTRAP_SCRIPT" | grep -nE '"DELETE"|method=.DELETE' || true)"
if [[ -n "$delete_hits" ]]; then
  fail "BOOTSTRAP_NO_DELETE: the reconciler contains a DELETE call: ${delete_hits%%$'\n'*}"
else
  pass "BOOTSTRAP_NO_DELETE: the reconciler has no DELETE call"
fi

prune_hits="$(script_code "$BOOTSTRAP_SCRIPT" | grep -nEi '\-\-prune|force_prune|forceprune|"force"' || true)"
if [[ -n "$prune_hits" ]]; then
  fail "BOOTSTRAP_NO_PRUNE: the reconciler contains a prune or force path: ${prune_hits%%$'\n'*}"
else
  pass "BOOTSTRAP_NO_PRUNE: the reconciler has no prune or force path (upsert-no-prune)"
fi

user_create_hits="$(script_code "$BOOTSTRAP_SCRIPT" | grep -nF '"POST", "/api/v3/core/users/"' || true)"
if [[ -n "$user_create_hits" ]]; then
  fail "BOOTSTRAP_NO_TECHNICAL_USER_CREATION: the reconciler posts to the users collection: ${user_create_hits%%$'\n'*}"
else
  pass "BOOTSTRAP_NO_TECHNICAL_USER_CREATION: the reconciler never creates a user object"
fi

random_hits="$(script_code "$BOOTSTRAP_SCRIPT" | grep -nE '\brandom\b|uuid4' || true)"
if [[ -n "$random_hits" ]]; then
  fail "BOOTSTRAP_NO_RANDOMNESS: the reconciler uses a random source, which breaks determinism: ${random_hits%%$'\n'*}"
else
  pass "BOOTSTRAP_NO_RANDOMNESS: the reconciler uses no random source"
fi

# ---------------------------------------------------------------------------
# 5. Consumers and documents stay consistent with the model
# ---------------------------------------------------------------------------
payload_hits="$(script_code "$ARGOCD_SSO_SCRIPT" | grep -nF '"attributes": {}' || true)"
if [[ -n "$payload_hits" ]]; then
  warn "CH04.6_GROUP_PAYLOAD_ADVISORY: $(rel "$ARGOCD_SSO_SCRIPT") line ${payload_hits%%:*}: group reconcile sends an empty attributes object, which clears CH04.5 managed ownership attributes; re-running the CH04.5 reconciler re-stamps them and a follow-up tracked change must make that payload attribute-preserving"
else
  pass "CH04.6_GROUP_PAYLOAD: the CH04.6 group payload does not clear managed ownership attributes"
fi

if grep -qF 'Identity group taxonomy' "$INVENTORY_DOC" \
   && grep -qF 'groups/platforminit-groups.yaml' "$INVENTORY_DOC" \
   && grep -qF 'CH04.5' "$INVENTORY_DOC"; then
  pass "INVENTORY_CONSISTENCY: the ownership inventory still attributes the group taxonomy to CH04.5"
else
  fail "INVENTORY_CONSISTENCY: the ownership inventory no longer attributes the group taxonomy to CH04.5"
fi

required_doc_strings=(
  'platforminit.identity.groups.v1'
  'platforminit.identity.bootstrap-users.v1'
  'platform/identity/groups/platforminit-groups.yaml'
  'platform/identity/users/bootstrap-technical-users.yaml'
  'platform/identity/scripts/ch04-5-bootstrap-identity-model.sh'
  'platform/identity/validate/ch04-5-validate-identity-model-contract.sh'
  'managed_by'
  'contract_version'
  'attribute_prefix'
  'owner_chapter'
  'owner_role'
  'consumer_chapter'
  'platforminit_managed_by'
  'upsert-no-prune'
  'membership-upsert-no-prune'
  'no-prune'
  'duplicate'
  'idempot'
  'deterministic'
  'create_by_default'
  'none-provisioned'
  'tracked-task-required'
  'attribute-preserving'
  'clientSecret'
  'PHASE 1'
  'PHASE 2'
  'PHASE 3'
  'git diff --check'
  'CH04.5'
  'CH04.6'
  'CH05'
)
missing_doc_strings=""
for needle in "${required_doc_strings[@]}"; do
  grep -qiF -- "$needle" "$CONTRACT_DOC" || missing_doc_strings="${missing_doc_strings} '${needle}'"
done
if [[ -z "${missing_doc_strings// /}" ]]; then
  pass "CONTRACT_DOC_CONTENT: the contract document states ownership, determinism, idempotence, template, consumer and validation rules"
else
  fail "CONTRACT_DOC_CONTENT: contract document is missing:${missing_doc_strings}"
fi

summary_exit
