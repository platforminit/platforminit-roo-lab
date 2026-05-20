#!/usr/bin/env bash
set -euo pipefail

pass() { echo "PASS | $1 | $2"; }
fail() { echo "FAIL | $1 | $2"; exit 1; }
warn() { echo "WARN | $1 | $2"; }

BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
EXPECTED_PROVIDER_SLUG="${ARGOCD_OIDC_PROVIDER_SLUG:-argocd}"
EXPECTED_ADMIN_GROUP="${ARGOCD_ADMIN_GROUP:-PlatformInit Admins}"
EXPECTED_ADMIN_USERNAME="${AUTHENTIK_ARGOCD_ADMIN_USERNAME:-akadmin}"
AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-https://auth.${BASE_DOMAIN}}"

kubectl -n "${IDENTITY_NAMESPACE}" rollout status deploy/authentik-server --timeout=10s >/dev/null 2>&1 && \
  pass "AUTHENTIK_ROLLOUT" "authentik-server rollout is healthy" || fail "AUTHENTIK_ROLLOUT" "authentik-server rollout is not healthy"

kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc >/dev/null 2>&1 && \
  pass "ARGOCD_OIDC_SECRET" "argocd-authentik-oidc secret exists" || fail "ARGOCD_OIDC_SECRET" "missing argocd-authentik-oidc secret"

client_id_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_ID}' 2>/dev/null || true)"
client_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_SECRET}' 2>/dev/null || true)"
client_id_value="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)"
dex_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.dex\.authentik\.clientSecret}' 2>/dev/null || true)"
server_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.server\.secretkey}' 2>/dev/null || true)"
[[ -n "${client_id_present}" ]] && pass "ARGOCD_CLIENT_ID" "client ID is stored in Kubernetes secret" || fail "ARGOCD_CLIENT_ID" "missing client ID"
[[ -n "${client_secret_present}" ]] && pass "ARGOCD_CLIENT_SECRET" "client secret is stored in Kubernetes secret" || fail "ARGOCD_CLIENT_SECRET" "missing client secret"
[[ -n "${dex_secret_present}" ]] && pass "ARGOCD_DEX_SECRET_REFERENCE" "argocd-secret contains dex.authentik.clientSecret" || fail "ARGOCD_DEX_SECRET_REFERENCE" "missing argocd-secret Dex clientSecret key"
[[ -n "${server_secret_present}" ]] && pass "ARGOCD_SERVER_SECRETKEY" "argocd-secret contains stable server.secretkey" || fail "ARGOCD_SERVER_SECRETKEY" "missing argocd-secret server.secretkey"

kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-dex-server --timeout=10s >/dev/null 2>&1 && \
  pass "ARGOCD_DEX_ROLLOUT" "Argo CD Dex server rollout is healthy" || fail "ARGOCD_DEX_ROLLOUT" "Argo CD Dex server rollout is not healthy"

kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=10s >/dev/null 2>&1 && \
  pass "ARGOCD_ROLLOUT" "Argo CD server rollout is healthy" || fail "ARGOCD_ROLLOUT" "Argo CD server rollout is not healthy"

config_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.dex\.config}' 2>/dev/null || true)"
direct_oidc_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.oidc\.config}' 2>/dev/null || true)"
rbac_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm -o jsonpath='{.data.policy\.csv}' 2>/dev/null || true)"
scopes_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm -o jsonpath='{.data.scopes}' 2>/dev/null || true)"

[[ -z "${direct_oidc_text}" ]] && \
  pass "ARGOCD_DIRECT_OIDC_DISABLED" "direct oidc.config is absent because CH04.6 uses Dex-backed SSO" || fail "ARGOCD_DIRECT_OIDC_DISABLED" "direct oidc.config is still present"

echo "${config_text}" | grep -q 'name: Authentik' && \
  pass "ARGOCD_DEX_CONNECTOR_NAME" "Argo CD Dex connector is named Authentik" || fail "ARGOCD_DEX_CONNECTOR_NAME" "Dex connector missing Authentik name"

echo "${config_text}" | grep -q 'type: oidc' && \
  pass "ARGOCD_DEX_CONNECTOR_TYPE" "Argo CD Dex connector type is oidc" || fail "ARGOCD_DEX_CONNECTOR_TYPE" "Dex connector type is not oidc"

echo "${config_text}" | grep -q "issuer: https://auth.${BASE_DOMAIN}/application/o/${EXPECTED_PROVIDER_SLUG}/" && \
  pass "ARGOCD_ISSUER" "Dex connector issuer points to Authentik provider" || fail "ARGOCD_ISSUER" "Dex connector issuer mismatch"

echo "${config_text}" | grep -q "clientID: ${client_id_value}" && \
  pass "ARGOCD_CLIENT_ID_MATCH" "Dex connector clientID matches stored client ID" || fail "ARGOCD_CLIENT_ID_MATCH" "Dex connector clientID mismatch"

echo "${config_text}" | grep -q 'clientSecret: \$dex.authentik.clientSecret' && \
  pass "ARGOCD_CLIENT_SECRET_REF" "Dex connector clientSecret uses argocd-secret reference" || fail "ARGOCD_CLIENT_SECRET_REF" "Dex connector clientSecret reference mismatch"

echo "${config_text}" | grep -q 'insecureEnableGroups: true' && \
  pass "ARGOCD_DEX_GROUPS_ENABLED" "Dex connector enables groups claim handling" || fail "ARGOCD_DEX_GROUPS_ENABLED" "Dex connector missing insecureEnableGroups"

echo "${config_text}" | grep -q -- '- groups' && \
  pass "ARGOCD_GROUP_SCOPE" "groups scope is requested" || fail "ARGOCD_GROUP_SCOPE" "groups scope missing"

echo "${rbac_text}" | grep -q "g, ${EXPECTED_ADMIN_GROUP}, role:admin" && \
  pass "ARGOCD_RBAC_ADMIN_GROUP" "admin group maps to role:admin" || warn "ARGOCD_RBAC_ADMIN_GROUP" "admin group mapping not found"

echo "${scopes_text}" | grep -q 'groups' && \
  pass "ARGOCD_RBAC_SCOPES" "RBAC scopes include groups" || warn "ARGOCD_RBAC_SCOPES" "RBAC scopes do not include groups"

if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  discovery_url="https://auth.${BASE_DOMAIN}/application/o/${EXPECTED_PROVIDER_SLUG}/.well-known/openid-configuration"
  discovery_json="$(curl -fsSL --retry 3 --retry-delay 2 "${discovery_url}" 2>/dev/null || true)"
  if [[ -n "${discovery_json}" ]]; then
    DISCOVERY_JSON="${discovery_json}" python3 - <<'PYALGS' && \
      pass "AUTHENTIK_OIDC_SIGNING_ALG" "OIDC discovery does not advertise symmetric-only HS* signing" || \
      fail "AUTHENTIK_OIDC_SIGNING_ALG" "OIDC discovery appears to advertise symmetric-only HS* signing"
import json
import os
import sys

doc = json.loads(os.environ["DISCOVERY_JSON"])
algs = doc.get("id_token_signing_alg_values_supported", []) or []
if algs and all(str(alg).upper().startswith("HS") for alg in algs):
    print("symmetric-only algorithms:", ",".join(map(str, algs)), file=sys.stderr)
    sys.exit(1)
print("algorithms:", ",".join(map(str, algs)) or "not-advertised")
PYALGS
  else
    warn "AUTHENTIK_OIDC_SIGNING_ALG" "skipped signing algorithm validation; discovery endpoint could not be fetched"
  fi
fi


# Validate Authentik-side group bootstrap when the bootstrap API token is available.
# This catches the exact post-login failure mode where SSO succeeds but Argo CD
# sync is denied because the authenticated admin user only receives the default
# readonly role.
read_secret_key() {
  local namespace="$1"
  local secret_name="$2"
  local key_name="$3"
  kubectl -n "${namespace}" get secret "${secret_name}" \
    -o "jsonpath={.data.${key_name}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"
if [[ -z "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]]; then
  AUTHENTIK_BOOTSTRAP_TOKEN="$(read_secret_key "${IDENTITY_NAMESPACE}" authentik-bootstrap AUTHENTIK_BOOTSTRAP_TOKEN)"
fi

if [[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]] && command -v python3 >/dev/null 2>&1; then
  AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL}" \
  AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN}" \
  EXPECTED_ADMIN_GROUP="${EXPECTED_ADMIN_GROUP}" \
  EXPECTED_ADMIN_USERNAME="${EXPECTED_ADMIN_USERNAME}" \
  python3 - <<'PYVALIDATE' || fail "AUTHENTIK_ARGOCD_ADMIN_GROUP" "admin group/user bootstrap validation failed"
import json
import os
import urllib.error
import urllib.parse
import urllib.request

base_url = os.environ["AUTHENTIK_BASE_URL"].rstrip("/")
token = os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"]
group_name = os.environ["EXPECTED_ADMIN_GROUP"]
username = os.environ["EXPECTED_ADMIN_USERNAME"]
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/json",
}


def request(path):
    req = urllib.request.Request(f"{base_url}{path}", headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def results(path):
    obj = request(path)
    if isinstance(obj, dict):
        return obj.get("results", [])
    if isinstance(obj, list):
        return obj
    return []


def exact(path, field, value):
    enc = urllib.parse.quote(value)
    for query in (f"{field}={enc}", f"search={enc}"):
        for item in results(f"{path}?{query}"):
            if item.get(field) == value:
                return item
    return None


def group_ids(raw):
    out = []
    for item in raw or []:
        if isinstance(item, str):
            out.append(item)
        elif isinstance(item, dict):
            val = item.get("pk") or item.get("id") or item.get("uuid")
            if val:
                out.append(val)
    return out


group = exact("/api/v3/core/groups/", "name", group_name)
if not group:
    raise SystemExit(f"missing Authentik group {group_name}")
if group.get("is_superuser"):
    raise SystemExit(f"group {group_name} must not be an Authentik superuser group")
if group.get("parent"):
    raise SystemExit(f"group {group_name} must not inherit from parent group {group.get('parent')}")

user = exact("/api/v3/core/users/", "username", username)
if not user:
    raise SystemExit(f"missing Authentik user {username}")
user_detail = request(f"/api/v3/core/users/{user['pk']}/")
if group["pk"] not in group_ids(user_detail.get("groups", [])):
    raise SystemExit(f"user {username} is not a member of {group_name}")

print(f"PASS | AUTHENTIK_ARGOCD_ADMIN_GROUP | {username} is a direct member of non-superuser {group_name}")
PYVALIDATE
else
  warn "AUTHENTIK_ARGOCD_ADMIN_GROUP" "skipped Authentik admin group membership validation; missing bootstrap token or python3"
fi

if command -v curl >/dev/null 2>&1; then
  if curl -fsSIk "https://argocd.${BASE_DOMAIN}" >/dev/null 2>&1; then
    pass "ARGOCD_HTTPS" "Argo CD URL responds over HTTPS"
  else
    warn "ARGOCD_HTTPS" "Argo CD HTTPS check failed from host; verify DNS/TLS externally"
  fi
fi
