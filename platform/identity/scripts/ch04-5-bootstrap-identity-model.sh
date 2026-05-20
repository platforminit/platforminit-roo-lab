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
import sys
import urllib.error
import urllib.parse
import urllib.request

base_url = os.environ["AUTHENTIK_BASE_URL"].rstrip("/")
token = os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"]
groups_file = os.environ["GROUPS_FILE"]
users_file = os.environ["USERS_FILE"]
bootstrap_username = os.environ.get("AUTHENTIK_BOOTSTRAP_ADMIN_USERNAME", "akadmin")

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


def paginated_results(path):
    obj = request("GET", path)
    if isinstance(obj, dict) and "results" in obj:
        return obj["results"]
    if isinstance(obj, list):
        return obj
    return []


def first_by_field(path, field, value):
    encoded = urllib.parse.quote(value)
    sep = "&" if "?" in path else "?"
    for query in (f"search={encoded}", f"{field}={encoded}"):
        for item in paginated_results(f"{path}{sep}{query}"):
            if item.get(field) == value:
                return item
    return None


def ensure_group(group):
    name = group["name"]
    payload = {
        "name": name,
        "is_superuser": bool(group.get("is_superuser", False)),
        "parent": None,
        "attributes": {
            "platforminit_scope": group.get("scope", "unspecified"),
            "platforminit_slug": group.get("slug", ""),
            "platforminit_description": group.get("description", ""),
        },
    }
    existing = first_by_field("/api/v3/core/groups/", "name", name)
    if existing:
        request("PATCH", f"/api/v3/core/groups/{existing['pk']}/", payload)
        print(f"Reconciled group: {name}")
        return existing["pk"]
    created = request("POST", "/api/v3/core/groups/", payload)
    print(f"Created group: {name}")
    return created["pk"]


def group_pk_list(raw_groups):
    values = []
    for item in raw_groups or []:
        if isinstance(item, str):
            values.append(item)
        elif isinstance(item, dict):
            value = item.get("pk") or item.get("id") or item.get("uuid")
            if value:
                values.append(value)
    return values


def find_user(username):
    encoded = urllib.parse.quote(username)
    for path in (
        f"/api/v3/core/users/?username={encoded}",
        f"/api/v3/core/users/?search={encoded}",
    ):
        for item in paginated_results(path):
            if item.get("username") == username:
                return item
    return None


def ensure_user_groups(username, target_group_pks):
    user = find_user(username)
    if not user:
        raise RuntimeError(f"Bootstrap Authentik user not found: {username}")
    user_pk = user["pk"]
    editable = request("GET", f"/api/v3/core/users/{user_pk}/")
    current = group_pk_list(editable.get("groups", []))
    changed = False
    for group_pk in target_group_pks:
        if group_pk not in current:
            current.append(group_pk)
            changed = True
    if changed:
        request("PATCH", f"/api/v3/core/users/{user_pk}/", {"groups": current})
        print(f"Updated bootstrap membership for user: {username}")
    else:
        print(f"Bootstrap membership already current for user: {username}")


request("GET", "/api/v3/core/users/me/")
groups_model = load_json_yaml_compatible(groups_file)
users_model = load_json_yaml_compatible(users_file)

group_pks = {}
for group in groups_model.get("groups", []):
    group_pks[group["name"]] = ensure_group(group)

for membership in users_model.get("bootstrap_memberships", []):
    username = bootstrap_username if membership.get("username_env") == "AUTHENTIK_BOOTSTRAP_ADMIN_USERNAME" else membership.get("default_username")
    if not username:
        username = membership.get("default_username")
    names = membership.get("groups", [])
    missing = [name for name in names if name not in group_pks]
    if missing:
        raise RuntimeError(f"Membership references missing groups: {missing}")
    ensure_user_groups(username, [group_pks[name] for name in names])

for user in users_model.get("technical_users", []):
    if user.get("create_by_default"):
        raise RuntimeError("Technical user auto-creation is intentionally disabled in CH04.5; set create_by_default=false")
    print(f"Documented technical user only: {user.get('username')}")
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
