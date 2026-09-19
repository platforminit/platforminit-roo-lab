#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH04.5][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IDENTITY_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
GROUPS_FILE="${IDENTITY_DIR}/groups/platforminit-groups.yaml"
USERS_FILE="${IDENTITY_DIR}/users/bootstrap-technical-users.yaml"

BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
AUTHENTIK_PUBLIC_BASE_URL="${AUTHENTIK_PUBLIC_BASE_URL:-https://auth.${BASE_DOMAIN}}"
AUTHENTIK_LOCAL_PORT="${AUTHENTIK_LOCAL_PORT:-18080}"
AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-http://127.0.0.1:${AUTHENTIK_LOCAL_PORT}}"
AUTHENTIK_USE_PORT_FORWARD="${AUTHENTIK_USE_PORT_FORWARD:-true}"
AUTHENTIK_BOOTSTRAP_ADMIN_USERNAME="${AUTHENTIK_BOOTSTRAP_ADMIN_USERNAME:-akadmin}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
PORT_FORWARD_PID=""
export BASE_DOMAIN IDENTITY_NAMESPACE AUTHENTIK_PUBLIC_BASE_URL AUTHENTIK_LOCAL_PORT AUTHENTIK_BASE_URL AUTHENTIK_USE_PORT_FORWARD AUTHENTIK_BOOTSTRAP_ADMIN_USERNAME KUBECONFIG GROUPS_FILE USERS_FILE

cleanup() {
  if [[ -n "${PORT_FORWARD_PID:-}" ]] && kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
    kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
    wait "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

read_secret_key() {
  local namespace="$1"
  local secret_name="$2"
  local key_name="$3"
  kubectl -n "${namespace}" get secret "${secret_name}" \
    -o "jsonpath={.data.${key_name}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

resolve_authentik_api_token() {
  AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"
  if [[ -z "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]]; then
    AUTHENTIK_BOOTSTRAP_TOKEN="$(read_secret_key "${IDENTITY_NAMESPACE}" authentik-bootstrap AUTHENTIK_BOOTSTRAP_TOKEN)"
  fi
  [[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]] || die "Missing AUTHENTIK_BOOTSTRAP_TOKEN; run 04.5 - Deploy Identity Foundation first"
  export AUTHENTIK_BOOTSTRAP_TOKEN
}

wait_for_authentik_api_token() {
  local timeout_seconds="${AUTHENTIK_TOKEN_READY_TIMEOUT_SECONDS:-600}"
  local interval_seconds="${AUTHENTIK_TOKEN_READY_INTERVAL_SECONDS:-10}"
  export AUTHENTIK_TOKEN_READY_TIMEOUT_SECONDS="${timeout_seconds}"
  export AUTHENTIK_TOKEN_READY_INTERVAL_SECONDS="${interval_seconds}"
  log "Waiting for Authentik bootstrap API token readiness against ${AUTHENTIK_BASE_URL}"

  python3 - <<'PYTOKEN'
import json
import os
import sys
import time
import urllib.error
import urllib.request

base_url = os.environ["AUTHENTIK_BASE_URL"].rstrip("/")
token = os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"]
timeout = int(os.environ.get("AUTHENTIK_TOKEN_READY_TIMEOUT_SECONDS", "600"))
interval = int(os.environ.get("AUTHENTIK_TOKEN_READY_INTERVAL_SECONDS", "10"))
deadline = time.time() + timeout
last_error = "not checked"
headers = {"Authorization": f"Bearer {token}", "Accept": "application/json"}

while time.time() < deadline:
    req = urllib.request.Request(f"{base_url}/api/v3/core/users/me/", method="GET", headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            payload = json.loads(raw) if raw else {}
            username = payload.get("username") or payload.get("user", {}).get("username") or "authenticated"
            print(f"Authentik API token is ready for user: {username}")
            sys.exit(0)
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace").strip()
        last_error = f"HTTP {exc.code}: {body}"
        if exc.code not in (401, 403):
            print(f"Unexpected Authentik API readiness error: {last_error}", file=sys.stderr)
    except urllib.error.URLError as exc:
        last_error = str(exc)
    time.sleep(interval)

print(
    f"Timed out after {timeout}s waiting for Authentik bootstrap API token to become valid. "
    f"Last error: {last_error}",
    file=sys.stderr,
)
sys.exit(1)
PYTOKEN
}

validate_prerequisites() {
  need kubectl
  need python3
  [[ -f "${GROUPS_FILE}" ]] || die "Missing groups file: ${GROUPS_FILE}"
  [[ -f "${USERS_FILE}" ]] || die "Missing users file: ${USERS_FILE}"
  [[ -f "${KUBECONFIG}" ]] || die "Missing kubeconfig: ${KUBECONFIG}"
  kubectl --kubeconfig "${KUBECONFIG}" get ns "${IDENTITY_NAMESPACE}" >/dev/null 2>&1 || die "Missing namespace: ${IDENTITY_NAMESPACE}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${IDENTITY_NAMESPACE}" rollout status deploy/authentik-server --timeout=90s >/dev/null || die "Authentik server is not healthy"
}

start_authentik_api_port_forward() {
  [[ "${AUTHENTIK_USE_PORT_FORWARD}" == "true" ]] || return 0

  case "${AUTHENTIK_BASE_URL}" in
    http://127.0.0.1:*|http://localhost:*) ;;
    *)
      log "Using external Authentik API endpoint: ${AUTHENTIK_BASE_URL}"
      return 0
      ;;
  esac

  log "Starting local Authentik API port-forward on 127.0.0.1:${AUTHENTIK_LOCAL_PORT}"
  kubectl --kubeconfig "${KUBECONFIG}" -n "${IDENTITY_NAMESPACE}" \
    port-forward --address 127.0.0.1 svc/authentik-server "${AUTHENTIK_LOCAL_PORT}:80" \
    >/tmp/ch04-5-authentik-port-forward.log 2>&1 &
  PORT_FORWARD_PID="$!"

  for _ in $(seq 1 60); do
    if ! kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
      cat /tmp/ch04-5-authentik-port-forward.log >&2 || true
      die "Authentik API port-forward exited before becoming ready"
    fi

    if python3 - <<PY >/dev/null 2>&1
import socket
s = socket.create_connection(("127.0.0.1", int("${AUTHENTIK_LOCAL_PORT}")), timeout=1)
s.close()
PY
    then
      log "Local Authentik API endpoint is ready: ${AUTHENTIK_BASE_URL}"
      return 0
    fi

    sleep 2
  done

  cat /tmp/ch04-5-authentik-port-forward.log >&2 || true
  die "Timed out waiting for local Authentik API port-forward"
}

bootstrap_identity_model() {
  log "Reconciling CH04.5 Authentik groups and bootstrap memberships"
  python3 - <<'PY'
import json
import os
import re
import sys
import urllib.error
import urllib.request

base_url = os.environ["AUTHENTIK_BASE_URL"].rstrip("/")
token = os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"]
groups_file = os.environ["GROUPS_FILE"]
users_file = os.environ["USERS_FILE"]
bootstrap_username = os.environ.get("AUTHENTIK_BOOTSTRAP_ADMIN_USERNAME", "akadmin")
api_page_size = int(os.environ.get("IDENTITY_API_PAGE_SIZE", "100"))
api_max_pages = int(os.environ.get("IDENTITY_API_MAX_PAGES", "25"))

GROUP_SCHEMA = "platforminit.identity.groups.v1"
USERS_SCHEMA = "platforminit.identity.bootstrap-users.v1"
RECONCILE_MODES = ("upsert-no-prune", "membership-upsert-no-prune")
SLUG_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")

headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/json",
    "Content-Type": "application/json",
}


def load_json_yaml_compatible(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def request(method, path, payload=None):
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(f"{base_url}{path}", data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {path} failed with HTTP {exc.code}: {body}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"{method} {path} failed against {base_url}: {exc}") from exc


def fail(message):
    print(f"CONTRACT_VIOLATION: {message}", file=sys.stderr)
    sys.exit(2)


def require_text(mapping, key, where):
    value = mapping.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"{where}: missing non-empty '{key}'")
    return value


def require_bool(mapping, key, where):
    value = mapping.get(key)
    if not isinstance(value, bool):
        fail(f"{where}: '{key}' must be a boolean")
    return value


def validate_management(model, where, expected_mode):
    management = model.get("management")
    if not isinstance(management, dict):
        fail(f"{where}: missing the 'management' ownership block")
    for key in ("managed_by", "reconcile_mode", "attribute_prefix", "owner_chapter"):
        require_text(management, key, f"{where}.management")
    mode = management["reconcile_mode"]
    if mode not in RECONCILE_MODES:
        fail(f"{where}: unsupported reconcile_mode '{mode}'")
    if mode != expected_mode:
        fail(f"{where}.management.reconcile_mode must be '{expected_mode}'")
    version = management.get("contract_version")
    if not isinstance(version, int) or isinstance(version, bool) or version < 1:
        fail(f"{where}.management.contract_version must be an integer >= 1")
    return management


def validate_group_references(entry, where, known_groups):
    referenced = entry.get("groups")
    if not isinstance(referenced, list) or not referenced:
        fail(f"{where}: 'groups' must be a non-empty list")
    unknown = sorted(name for name in referenced if name not in known_groups)
    if unknown:
        fail(f"{where}: references unknown groups: {','.join(unknown)}")


def validate_groups_model(model):
    if model.get("schema") != GROUP_SCHEMA:
        fail(f"group model schema must be '{GROUP_SCHEMA}'")
    management = validate_management(model, "groups model", "upsert-no-prune")
    groups = model.get("groups")
    if not isinstance(groups, list) or not groups:
        fail("group model must define a non-empty 'groups' list")
    names = set()
    slugs = set()
    superusers = []
    for group in groups:
        if not isinstance(group, dict):
            fail("every group entry must be an object")
        name = require_text(group, "name", "group entry")
        slug = require_text(group, "slug", f"group '{name}'")
        require_text(group, "description", f"group '{name}'")
        scope = require_text(group, "scope", f"group '{name}'")
        require_text(group, "owner_chapter", f"group '{name}'")
        require_text(group, "owner_role", f"group '{name}'")
        require_text(group, "consumer_chapter", f"group '{name}'")
        is_superuser = require_bool(group, "is_superuser", f"group '{name}'")
        if not SLUG_RE.match(slug):
            fail(f"group '{name}': slug '{slug}' is not a lowercase hyphenated token")
        if name in names:
            fail(f"duplicate group name in the model: {name}")
        if slug in slugs:
            fail(f"duplicate group slug in the model: {slug}")
        names.add(name)
        slugs.add(slug)
        if is_superuser:
            if scope.startswith("application:"):
                fail(f"application-scoped group '{name}' must not be an Authentik superuser group")
            superusers.append(group)
    if len(superusers) != 1:
        fail(f"exactly one Authentik superuser group is required, found {len(superusers)}")
    only_superuser = superusers[0]
    if only_superuser["scope"] != "identity-platform" or only_superuser["consumer_chapter"] != "identity":
        fail(f"superuser group '{only_superuser['name']}' must stay in the identity-platform scope")
    return management


def validate_users_model(model, groups_model):
    if model.get("schema") != USERS_SCHEMA:
        fail(f"bootstrap users schema must be '{USERS_SCHEMA}'")
    management = validate_management(model, "bootstrap users model", "membership-upsert-no-prune")
    creation = require_text(management, "technical_user_creation", "bootstrap users model management")
    if creation != "disabled":
        fail("technical user creation must stay 'disabled' until a tracked task enables it")
    known_groups = {group["name"] for group in groups_model.get("groups", [])}
    memberships = model.get("bootstrap_memberships")
    technical_users = model.get("technical_users")
    if not isinstance(memberships, list) or not memberships:
        fail("bootstrap users model must define at least one bootstrap membership")
    if not isinstance(technical_users, list):
        fail("bootstrap users model must define a 'technical_users' list")
    bootstrap_usernames = set()
    for membership in memberships:
        if not isinstance(membership, dict):
            fail("every bootstrap membership must be an object")
        default_username = require_text(membership, "default_username", "bootstrap membership")
        for key in ("identity_kind", "owner_chapter", "owner_role", "credential_source", "rotation_policy"):
            require_text(membership, key, f"bootstrap membership '{default_username}'")
        validate_group_references(membership, f"bootstrap membership '{default_username}'", known_groups)
        bootstrap_usernames.add(default_username)
    seen_usernames = set()
    for user in technical_users:
        if not isinstance(user, dict):
            fail("every technical user entry must be an object")
        username = require_text(user, "username", "technical user")
        for key in (
            "display_name",
            "purpose",
            "identity_kind",
            "owner_chapter",
            "owner_role",
            "credential_source",
            "rotation_policy",
            "enablement_gate",
        ):
            require_text(user, key, f"technical user '{username}'")
        if require_bool(user, "create_by_default", f"technical user '{username}'"):
            fail(f"technical user '{username}': CH04.5 must not auto-create technical identities (create_by_default must be false)")
        if username in bootstrap_usernames:
            fail(f"technical user '{username}' collides with a bootstrap membership identity")
        if username in seen_usernames:
            fail(f"duplicate technical user in the model: {username}")
        seen_usernames.add(username)
        validate_group_references(user, f"technical user '{username}'", known_groups)
    return management


def index_by_name(items, field):
    index = {}
    for item in items:
        value = item.get(field)
        if value is None:
            continue
        index.setdefault(value, []).append(item)
    return index


def list_pages(resource_path):
    collected = {}
    for page in range(1, api_max_pages + 1):
        separator = "&" if "?" in resource_path else "?"
        payload = request("GET", f"{resource_path}{separator}page={page}&page_size={api_page_size}")
        if isinstance(payload, dict) and "results" in payload:
            batch = payload["results"]
        elif isinstance(payload, list):
            batch = payload
        else:
            batch = []
        for item in batch:
            key = item.get("pk")
            if key is None:
                key = item.get("uuid") or item.get("username") or item.get("name")
            if key is None:
                continue
            collected[key] = item
        if len(batch) < api_page_size:
            break
    return list(collected.values())


def unique_match(index, name, kind):
    matches = index.get(name, [])
    if len(matches) > 1:
        pks = ",".join(sorted(str(item.get("pk")) for item in matches))
        fail(f"duplicate {kind} '{name}' detected (pks={pks}); refusing to reconcile so no duplicate object is compounded")
    return matches[0] if matches else None


def managed_attributes(group, management):
    prefix = management["attribute_prefix"]
    return {
        f"{prefix}_managed_by": management["managed_by"],
        f"{prefix}_contract_version": str(management["contract_version"]),
        f"{prefix}_owner_chapter": group["owner_chapter"],
        f"{prefix}_owner_role": group["owner_role"],
        f"{prefix}_consumer_chapter": group["consumer_chapter"],
        f"{prefix}_scope": group["scope"],
        f"{prefix}_slug": group["slug"],
        f"{prefix}_description": group["description"],
    }


def current_group_attributes(item, pk):
    attributes = item.get("attributes")
    if isinstance(attributes, dict):
        return attributes
    detail = request("GET", f"/api/v3/core/groups/{pk}/")
    detail_attributes = detail.get("attributes")
    return detail_attributes if isinstance(detail_attributes, dict) else {}


def ensure_group(group, management, groups_by_name):
    name = group["name"]
    desired_superuser = group["is_superuser"]
    desired_attributes = managed_attributes(group, management)
    existing = unique_match(groups_by_name, name, "group")
    if existing is None:
        created = request("POST", "/api/v3/core/groups/", {
            "name": name,
            "is_superuser": desired_superuser,
            "parent": None,
            "attributes": desired_attributes,
        })
        print(f"CREATE group: {name} pk={created.get('pk')}")
        return created["pk"]
    pk = existing["pk"]
    current_attributes = current_group_attributes(existing, pk)
    drift = []
    if bool(existing.get("is_superuser", False)) != desired_superuser:
        drift.append("is_superuser")
    for key in sorted(desired_attributes):
        if str(current_attributes.get(key, "")) != str(desired_attributes[key]):
            drift.append(key)
    if not drift:
        print(f"UNCHANGED group: {name} pk={pk}")
        return pk
    request("PATCH", f"/api/v3/core/groups/{pk}/", {
        "name": name,
        "is_superuser": desired_superuser,
        "parent": None,
        "attributes": desired_attributes,
    })
    print(f"RECONCILE group: {name} pk={pk} drift={','.join(sorted(drift))}")
    return pk


def group_pk_map(raw_groups):
    """Normalized primary key -> original value.

    The API may serialize membership as primary keys or as nested objects, and
    as integers or strings. Comparison is always done on the normalized string
    form so a stable membership is never rewritten just because of its wire
    type, while the original value is preserved for the PATCH payload.
    """
    mapping = {}
    for item in raw_groups or []:
        if isinstance(item, dict):
            value = item.get("pk") or item.get("id") or item.get("uuid")
        elif isinstance(item, (str, int)):
            value = item
        else:
            value = None
        if value is None:
            continue
        mapping.setdefault(str(value), value)
    return mapping


def ensure_memberships(username, desired_group_names, group_pks, users_by_username):
    user = unique_match(users_by_username, username, "user")
    if user is None:
        fail(f"bootstrap identity not found: {username}")
    user_pk = user["pk"]
    detail = request("GET", f"/api/v3/core/users/{user_pk}/")
    raw_current = detail.get("groups", [])
    current_map = group_pk_map(raw_current)
    desired_map = {str(group_pks[name]): group_pks[name] for name in desired_group_names}
    missing = sorted(key for key in desired_map if key not in current_map)
    duplicates = len(current_map) != len(raw_current)
    if not missing and not duplicates:
        print(f"UNCHANGED membership: {username} managed_groups={len(desired_map)}")
        return
    merged = [current_map.get(key, desired_map[key]) for key in sorted(set(current_map) | set(desired_map))]
    request("PATCH", f"/api/v3/core/users/{user_pk}/", {"groups": merged})
    preserved = len(set(current_map) - set(desired_map))
    print(
        f"RECONCILE membership: {username} added={len(missing)} "
        f"deduplicated={duplicates} preserved={preserved}"
    )


# --- PHASE 1: read-only identity model contract validation (no mutation) ---
groups_model = load_json_yaml_compatible(groups_file)
users_model = load_json_yaml_compatible(users_file)
groups_management = validate_groups_model(groups_model)
users_management = validate_users_model(users_model, groups_model)
if users_management["managed_by"] != groups_management["managed_by"]:
    fail("bootstrap users model management.managed_by must match the group model")
if users_management["contract_version"] != groups_management["contract_version"]:
    fail("bootstrap users model management.contract_version must match the group model")
print(
    "Model contract OK: "
    f"groups={len(groups_model['groups'])} "
    f"bootstrap_memberships={len(users_model['bootstrap_memberships'])} "
    f"technical_users={len(users_model['technical_users'])} "
    f"contract_version={groups_management['contract_version']}"
)

# --- PHASE 2: read-only Authentik API state (no mutation) ---
request("GET", "/api/v3/core/users/me/")
groups_by_name = index_by_name(list_pages("/api/v3/core/groups/"), "name")
users_by_username = index_by_name(list_pages("/api/v3/core/users/"), "username")

# --- PHASE 3: idempotent reconciliation (deterministic order, upsert, no prune) ---
group_pks = {}
for group in sorted(groups_model["groups"], key=lambda item: item["name"]):
    group_pks[group["name"]] = ensure_group(group, groups_management, groups_by_name)

for membership in sorted(users_model["bootstrap_memberships"], key=lambda item: item["default_username"]):
    username = membership["default_username"]
    if membership.get("username_env") == "AUTHENTIK_BOOTSTRAP_ADMIN_USERNAME":
        username = bootstrap_username
    ensure_memberships(username, sorted(membership["groups"]), group_pks, users_by_username)

for technical_user in sorted(users_model["technical_users"], key=lambda item: item["username"]):
    print(
        "DOCUMENTED technical identity only (create_by_default=false): "
        f"{technical_user['username']} owner={technical_user['owner_chapter']}/{technical_user['owner_role']}"
    )
PY
}

main() {
  validate_prerequisites
  start_authentik_api_port_forward
  resolve_authentik_api_token
  wait_for_authentik_api_token
  bootstrap_identity_model
  log "CH04.5 identity foundation bootstrap completed"
}

main "$@"
