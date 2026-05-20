#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH04.6][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_OIDC_PROVIDER_SLUG="${ARGOCD_OIDC_PROVIDER_SLUG:-argocd}"
ARGOCD_OIDC_CLIENT_ID="${ARGOCD_OIDC_CLIENT_ID:-}"
ARGOCD_OIDC_CLIENT_SECRET="${ARGOCD_OIDC_CLIENT_SECRET:-}"
ARGOCD_ADMIN_GROUP="${ARGOCD_ADMIN_GROUP:-PlatformInit Admins}"
AUTHENTIK_ARGOCD_ADMIN_USERNAME="${AUTHENTIK_ARGOCD_ADMIN_USERNAME:-akadmin}"
AUTHENTIK_ARGOCD_SIGNING_KEY_NAME="${AUTHENTIK_ARGOCD_SIGNING_KEY_NAME:-}"
AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL:-https://auth.${BASE_DOMAIN}}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
ARGOCD_CONFIG_CHANGED=0
ARGOCD_PREVIOUS_CM_FILE=""
ARGOCD_PREVIOUS_RBAC_FILE=""
AUTHENTIK_OIDC_ISSUER=""

ensure_runtime_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends curl ca-certificates python3 openssl >/dev/null
}

ensure_cluster_ready() {
  need kubectl
  [ -f "${KUBECONFIG}" ] || die "Missing kubeconfig: ${KUBECONFIG}"
  kubectl --kubeconfig "${KUBECONFIG}" get nodes >/dev/null 2>&1 || die "kubectl cannot access cluster via ${KUBECONFIG}"
}

read_secret_key() {
  local namespace="$1"
  local secret_name="$2"
  local key_name="$3"
  kubectl -n "${namespace}" get secret "${secret_name}" \
    -o "jsonpath={.data.${key_name}}" 2>/dev/null | base64 -d 2>/dev/null || true
}

validate_prerequisites() {
  kubectl get ns "${IDENTITY_NAMESPACE}" >/dev/null 2>&1 || die "Missing namespace: ${IDENTITY_NAMESPACE}; deploy 04.5 - Deploy Identity Foundation first"
  kubectl get ns "${ARGOCD_NAMESPACE}" >/dev/null 2>&1 || die "Missing namespace: ${ARGOCD_NAMESPACE}; deploy CH04 first"
  kubectl -n "${IDENTITY_NAMESPACE}" rollout status deploy/authentik-server --timeout=30s >/dev/null || die "Authentik server is not healthy"
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy/argocd-server >/dev/null 2>&1 || die "Missing deployment: ${ARGOCD_NAMESPACE}/argocd-server"

  # Do not fail the whole SSO reconciliation if Argo CD is already in a
  # ProgressDeadlineExceeded state from a previous restart. CH04.6 is allowed
  # to repair/restart argocd-server after reconciling the OIDC config.
  if ! kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=30s >/dev/null 2>&1; then
    log "WARN: Argo CD server is not currently healthy; continuing so the SSO repair/restart path can run"
    diagnose_argocd_server_rollout || true
  fi
}

ensure_argocd_server_secretkey() {
  log "Ensuring argocd-secret contains stable server.secretkey before SSO login"

  local existing_key=""
  existing_key="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.server\.secretkey}' 2>/dev/null || true)"
  if [[ -n "${existing_key}" ]]; then
    log "argocd-secret server.secretkey already present"
    return 0
  fi

  local raw_key=""
  local encoded_key=""
  raw_key="$(openssl rand -base64 32)"
  encoded_key="$(printf '%s' "${raw_key}" | base64 -w0)"

  kubectl -n "${ARGOCD_NAMESPACE}" patch secret argocd-secret --type=merge \
    -p "{\"data\":{\"server.secretkey\":\"${encoded_key}\"}}" >/dev/null

  log "Created stable argocd-secret server.secretkey for OIDC state/session token verification"
}

resolve_or_create_argocd_oidc_secret() {
  local existing_id=""
  local existing_secret=""

  existing_id="$(read_secret_key "${ARGOCD_NAMESPACE}" argocd-authentik-oidc ARGOCD_OIDC_CLIENT_ID)"
  existing_secret="$(read_secret_key "${ARGOCD_NAMESPACE}" argocd-authentik-oidc ARGOCD_OIDC_CLIENT_SECRET)"

  if [[ -n "${ARGOCD_OIDC_CLIENT_ID}" && -n "${ARGOCD_OIDC_CLIENT_SECRET}" ]]; then
    log "Using provided Argo CD OIDC client credentials from environment"
  elif [[ -n "${existing_id}" && -n "${existing_secret}" ]]; then
    log "Reusing existing Argo CD OIDC client credentials from Kubernetes secret"
    ARGOCD_OIDC_CLIENT_ID="${existing_id}"
    ARGOCD_OIDC_CLIENT_SECRET="${existing_secret}"
  else
    log "Generating Argo CD OIDC client credentials inside the cluster automation"
    ARGOCD_OIDC_CLIENT_ID="platforminit-argocd"
    ARGOCD_OIDC_CLIENT_SECRET="$(openssl rand -hex 48)"
  fi

  [[ -n "${ARGOCD_OIDC_CLIENT_ID}" ]] || die "Failed to resolve Argo CD OIDC client id"
  [[ -n "${ARGOCD_OIDC_CLIENT_SECRET}" ]] || die "Failed to resolve Argo CD OIDC client secret"
  export ARGOCD_OIDC_CLIENT_ID ARGOCD_OIDC_CLIENT_SECRET

  kubectl -n "${ARGOCD_NAMESPACE}" create secret generic argocd-authentik-oidc \
    --from-literal=ARGOCD_OIDC_CLIENT_ID="${ARGOCD_OIDC_CLIENT_ID}" \
    --from-literal=ARGOCD_OIDC_CLIENT_SECRET="${ARGOCD_OIDC_CLIENT_SECRET}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  local patch_payload=""
  patch_payload="$(python3 - <<'PY'
import base64
import json
import os
import sys

secret = os.environ.get("ARGOCD_OIDC_CLIENT_SECRET", "")
if not secret:
    print("ARGOCD_OIDC_CLIENT_SECRET is empty; refusing to render argocd-secret patch", file=sys.stderr)
    sys.exit(1)

encoded = base64.b64encode(secret.encode()).decode()
print(json.dumps({"data": {
    "dex.authentik.clientSecret": encoded,
    "oidc.authentik.clientSecret": encoded,
}}))
PY
)"

  kubectl -n "${ARGOCD_NAMESPACE}" patch secret argocd-secret --type='merge' -p "${patch_payload}" >/dev/null
}

resolve_authentik_api_token() {
  AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"
  if [[ -z "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]]; then
    AUTHENTIK_BOOTSTRAP_TOKEN="$(read_secret_key "${IDENTITY_NAMESPACE}" authentik-bootstrap AUTHENTIK_BOOTSTRAP_TOKEN)"
  fi
  [[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]] || die "Missing AUTHENTIK_BOOTSTRAP_TOKEN; re-run 04.5 - Deploy Identity Foundation to create/preserve authentik-bootstrap secret"
  export AUTHENTIK_BOOTSTRAP_TOKEN
}

configure_authentik_argocd_provider() {
  log "Reconciling Authentik Argo CD provider/application via Authentik API"
  export BASE_DOMAIN AUTHENTIK_BASE_URL ARGOCD_OIDC_PROVIDER_SLUG ARGOCD_OIDC_CLIENT_ID ARGOCD_OIDC_CLIENT_SECRET ARGOCD_ADMIN_GROUP AUTHENTIK_ARGOCD_ADMIN_USERNAME AUTHENTIK_ARGOCD_SIGNING_KEY_NAME

  python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request

base_domain = os.environ["BASE_DOMAIN"]
base_url = os.environ["AUTHENTIK_BASE_URL"].rstrip("/")
token = os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"]
provider_slug = os.environ.get("ARGOCD_OIDC_PROVIDER_SLUG", "argocd")
client_id = os.environ["ARGOCD_OIDC_CLIENT_ID"]
client_secret = os.environ["ARGOCD_OIDC_CLIENT_SECRET"]
admin_group_name = os.environ.get("ARGOCD_ADMIN_GROUP", "PlatformInit Admins")
admin_username = os.environ.get("AUTHENTIK_ARGOCD_ADMIN_USERNAME", "akadmin")
preferred_signing_key_name = os.environ.get("AUTHENTIK_ARGOCD_SIGNING_KEY_NAME", "").strip()

argocd_url = f"https://argocd.{base_domain}"
redirect_uri = f"{argocd_url}/api/dex/callback"
logout_uri = f"{argocd_url}/logout"
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/json",
    "Content-Type": "application/json",
}


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


def paginated_results(path):
    obj = request("GET", path)
    if isinstance(obj, dict) and "results" in obj:
        return obj["results"]
    if isinstance(obj, list):
        return obj
    return []


def first_by_field(path, field, value):
    sep = "&" if "?" in path else "?"
    encoded = urllib.parse.quote(value)
    for query in (f"search={encoded}", f"{field}={encoded}"):
        for item in paginated_results(f"{path}{sep}{query}"):
            if item.get(field) == value:
                return item
    return None


def flow_pk(slug):
    flow = first_by_field("/api/v3/flows/instances/", "slug", slug)
    if not flow:
        raise RuntimeError(f"Required Authentik flow not found: {slug}")
    return flow["pk"]


def default_scope_pks():
    wanted_scopes = {"openid", "email", "profile"}
    results = paginated_results("/api/v3/propertymappings/provider/scope/?page_size=200")
    found = []
    seen = set()
    for item in results:
        name = item.get("name", "")
        scope_name = item.get("scope_name", "")
        normalized = name.lower()
        scope_matches = scope_name in wanted_scopes
        name_matches = any(f"'{scope}'" in normalized for scope in wanted_scopes)
        if (scope_matches or name_matches) and item.get("pk") not in seen:
            found.append(item["pk"])
            seen.add(item["pk"])
    if len(found) < 3:
        print("WARN: fewer default openid/email/profile scope mappings found than expected; continuing with available mappings", file=sys.stderr)
    return found


def ensure_argocd_groups_scope_mapping():
    mapping_name = "PlatformInit Argo CD Groups"
    expression = '''
# Emit Authentik group names into the OIDC ID token for Argo CD RBAC.
# Argo CD maps these values through argocd-rbac-cm policy.csv.
return {
    "groups": [group.name for group in request.user.ak_groups.all()],
}
'''.strip()
    payload = {
        "name": mapping_name,
        "scope_name": "groups",
        "description": "PlatformInit Argo CD RBAC groups claim",
        "expression": expression,
    }
    existing = first_by_field("/api/v3/propertymappings/provider/scope/", "name", mapping_name)
    if existing:
        request("PATCH", f"/api/v3/propertymappings/provider/scope/{existing['pk']}/", payload)
        print(f"Updated Authentik scope mapping {mapping_name} pk={existing['pk']}")
        return existing["pk"]

    created = request("POST", "/api/v3/propertymappings/provider/scope/", payload)
    print(f"Created Authentik scope mapping {mapping_name} pk={created['pk']}")
    return created["pk"]

def ensure_authentik_group(name):
    existing = first_by_field("/api/v3/core/groups/", "name", name)
    desired_payload = {
        "name": name,
        "is_superuser": False,
        "parent": None,
        "attributes": {},
    }

    if existing:
        # Keep the Argo CD RBAC group application-scoped. It must not inherit
        # broad Authentik administrator privileges and must not become an
        # Authentik superuser group. Argo CD only needs the group claim name.
        request("PATCH", f"/api/v3/core/groups/{existing['pk']}/", desired_payload)
        print(f"Reconciled Authentik group {name} pk={existing['pk']} as non-superuser application group")
        return existing["pk"]

    created = request("POST", "/api/v3/core/groups/", desired_payload)
    print(f"Created Authentik group {name} pk={created['pk']}")
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


def find_user_by_username(username):
    # Prefer an exact username lookup and fall back to Authentik's search
    # endpoint because different Authentik versions expose slightly different
    # filter behaviour for core users.
    encoded = urllib.parse.quote(username)
    for path in (
        f"/api/v3/core/users/?username={encoded}",
        f"/api/v3/core/users/?search={encoded}",
    ):
        for item in paginated_results(path):
            if item.get("username") == username:
                return item
    return None


def ensure_user_in_group(user, group_pk, group_name):
    user_pk = user.get("pk")
    username = user.get("username") or user.get("name") or user_pk
    if not user_pk:
        raise RuntimeError(f"Could not resolve Authentik user pk for {username}")

    editable_user = request("GET", f"/api/v3/core/users/{user_pk}/")
    groups = group_pk_list(editable_user.get("groups", []))
    if group_pk in groups:
        print(f"Authentik user {username} is already a member of {group_name}")
        return

    groups.append(group_pk)
    request("PATCH", f"/api/v3/core/users/{user_pk}/", {"groups": groups})
    print(f"Added Authentik user {username} to {group_name} for Argo CD RBAC")


def ensure_argocd_admin_membership(group_pk, group_name, username):
    user = find_user_by_username(username)
    if not user:
        raise RuntimeError(
            f"Required Authentik Argo CD admin user not found: {username}. "
            "Set AUTHENTIK_ARGOCD_ADMIN_USERNAME if the bootstrap admin username differs."
        )

    ensure_user_in_group(user, group_pk, group_name)


def resolve_oauth_signing_key():
    """Resolve an Authentik certificate/key pair for asymmetric OIDC signing.

    Without an explicit signing key, Authentik OAuth2 providers can fall back to
    symmetric HS* token signing. Argo CD/Dex is more reliable with a normal OIDC
    JWKS-backed asymmetric provider, so CH04.6 treats signing_key as mandatory.
    """
    keys = paginated_results("/api/v3/crypto/certificatekeypairs/?page_size=200")
    if not keys:
        raise RuntimeError(
            "No Authentik certificate/key pairs found. Create or generate one before enabling Argo CD SSO."
        )

    def key_name(item):
        return str(item.get("name") or item.get("managed") or item.get("pk") or "")

    def key_type(item):
        return str(item.get("key_type") or item.get("type") or item.get("algorithm") or "").lower()

    def has_private_key(item):
        # Different Authentik versions expose this slightly differently. Only
        # reject explicit false values; otherwise keep the key as a candidate.
        value = item.get("has_key", item.get("has_private_key", None))
        return value is not False

    if preferred_signing_key_name:
        for item in keys:
            if key_name(item) == preferred_signing_key_name:
                if not has_private_key(item):
                    raise RuntimeError(f"Preferred signing key has no private key: {preferred_signing_key_name}")
                print(f"Using configured Authentik signing key {key_name(item)} pk={item['pk']}")
                return item["pk"]
        raise RuntimeError(f"Configured Authentik signing key was not found: {preferred_signing_key_name}")

    # Prefer RSA because this yields the expected RS256-style OIDC/JWKS path for
    # consumers such as Argo CD/Dex.
    for item in keys:
        if has_private_key(item) and key_type(item) == "rsa":
            print(f"Using Authentik RSA signing key {key_name(item)} pk={item['pk']}")
            return item["pk"]

    # Common default name in Authentik installs. Keep this fallback even if the
    # API response does not expose key_type.
    for item in keys:
        name = key_name(item).lower()
        if has_private_key(item) and "authentik" in name and "self" in name and "sign" in name:
            print(f"Using Authentik self-signed signing key {key_name(item)} pk={item['pk']}")
            return item["pk"]

    for item in keys:
        if has_private_key(item):
            print(f"Using first available Authentik signing key {key_name(item)} pk={item['pk']}")
            return item["pk"]

    raise RuntimeError("No usable Authentik signing key with a private key was found")

request("GET", "/api/v3/core/users/me/")
authorization_flow = flow_pk("default-provider-authorization-implicit-consent")
invalidation_flow = flow_pk("default-provider-invalidation-flow")
property_mappings = default_scope_pks()
argocd_groups_mapping_pk = ensure_argocd_groups_scope_mapping()
if argocd_groups_mapping_pk not in property_mappings:
    property_mappings.append(argocd_groups_mapping_pk)

argocd_admin_group_pk = ensure_authentik_group(admin_group_name)
ensure_argocd_admin_membership(argocd_admin_group_pk, admin_group_name, admin_username)
argocd_signing_key_pk = resolve_oauth_signing_key()

provider_payload = {
    "name": "Argo CD",
    "authorization_flow": authorization_flow,
    "invalidation_flow": invalidation_flow,
    "client_type": "confidential",
    "grant_types": ["authorization_code", "refresh_token"],
    "client_id": client_id,
    "client_secret": client_secret,
    "redirect_uris": [
        {"matching_mode": "strict", "url": redirect_uri, "redirect_uri_type": "authorization"},
        {"matching_mode": "strict", "url": "https://localhost:8085/auth/callback", "redirect_uri_type": "authorization"},
        {"matching_mode": "strict", "url": logout_uri, "redirect_uri_type": "logout"},
    ],
    "logout_uri": logout_uri,
    "logout_method": "frontchannel",
    "sub_mode": "hashed_user_id",
    "issuer_mode": "per_provider",
    "include_claims_in_id_token": True,
    "signing_key": argocd_signing_key_pk,
}
if property_mappings:
    provider_payload["property_mappings"] = property_mappings

provider = first_by_field("/api/v3/providers/oauth2/", "name", "Argo CD")
if provider:
    provider_pk = provider["pk"]
    request("PATCH", f"/api/v3/providers/oauth2/{provider_pk}/", provider_payload)
    print(f"Updated Authentik OAuth provider Argo CD pk={provider_pk}")
else:
    provider = request("POST", "/api/v3/providers/oauth2/", provider_payload)
    provider_pk = provider["pk"]
    print(f"Created Authentik OAuth provider Argo CD pk={provider_pk}")

app_payload = {
    "name": "Argo CD",
    "slug": provider_slug,
    "provider": provider_pk,
    "open_in_new_tab": True,
    "meta_launch_url": argocd_url,
    "meta_description": "PlatformInit GitOps control plane",
    "meta_publisher": "PlatformInit",
}
app = first_by_field("/api/v3/core/applications/", "slug", provider_slug)
if app:
    request("PATCH", f"/api/v3/core/applications/{provider_slug}/", app_payload)
    print(f"Updated Authentik application slug={provider_slug}")
else:
    request("POST", "/api/v3/core/applications/", app_payload)
    print(f"Created Authentik application slug={provider_slug}")
PY
}

validate_authentik_oidc_discovery() {
  local provider_issuer="${AUTHENTIK_BASE_URL%/}/application/o/${ARGOCD_OIDC_PROVIDER_SLUG}/"
  local discovery_url="${provider_issuer}.well-known/openid-configuration"
  local discovery_json=""

  log "Validating Authentik OIDC discovery endpoint for Argo CD"
  discovery_json="$(curl -fsSL --retry 3 --retry-delay 2 "${discovery_url}")" || die "Failed to fetch OIDC discovery document: ${discovery_url}"

  AUTHENTIK_OIDC_ISSUER="$(DISCOVERY_JSON="${discovery_json}" python3 - <<'PY'
import json
import os
import sys

try:
    doc = json.loads(os.environ["DISCOVERY_JSON"])
except Exception as exc:
    print(f"Invalid OIDC discovery JSON: {exc}", file=sys.stderr)
    sys.exit(1)

issuer = doc.get("issuer", "")
authorization_endpoint = doc.get("authorization_endpoint", "")
token_endpoint = doc.get("token_endpoint", "")
jwks_uri = doc.get("jwks_uri", "")
algorithms = doc.get("id_token_signing_alg_values_supported", []) or []

missing = [name for name, value in {
    "issuer": issuer,
    "authorization_endpoint": authorization_endpoint,
    "token_endpoint": token_endpoint,
    "jwks_uri": jwks_uri,
}.items() if not value]
if missing:
    print(f"OIDC discovery document is missing required keys: {', '.join(missing)}", file=sys.stderr)
    sys.exit(1)

if algorithms:
    symmetric_only = all(str(alg).upper().startswith("HS") for alg in algorithms)
    if symmetric_only:
        print(
            "OIDC discovery advertises only symmetric HS* signing algorithms; "
            "CH04.6 requires an asymmetric Authentik signing_key for Argo CD/Dex",
            file=sys.stderr,
        )
        sys.exit(1)

print(issuer)
PY
)"

  [[ -n "${AUTHENTIK_OIDC_ISSUER}" ]] || die "Failed to resolve Authentik OIDC issuer from discovery document"
  export AUTHENTIK_OIDC_ISSUER
  log "Using discovered Authentik OIDC issuer: ${AUTHENTIK_OIDC_ISSUER}"

  kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.dex\.authentik\.clientSecret}' | grep -q . \
    || die "argocd-secret is missing dex.authentik.clientSecret after secret reconciliation"
}


validate_authentik_oidc_discovery_from_cluster() {
  local discovery_url="${AUTHENTIK_OIDC_ISSUER%/}/.well-known/openid-configuration"
  local probe_name="argocd-oidc-discovery-probe-$(date +%s)"
  local probe_output=""

  log "Validating Authentik OIDC discovery endpoint from inside the cluster"
  if ! probe_output="$(kubectl -n "${ARGOCD_NAMESPACE}" run "${probe_name}" \
      --image=curlimages/curl:8.10.1 \
      --restart=Never \
      --rm \
      --attach \
      --quiet \
      --pod-running-timeout=90s \
      --command -- sh -c "curl -fsSL --connect-timeout 10 --max-time 30 '${discovery_url}' | grep -q '\"issuer\"'" 2>&1)"; then
    echo "${probe_output}" >&2
    remove_argocd_oidc_config_for_recovery || true
    die "OIDC discovery is reachable from the host workflow but not from inside the cluster: ${discovery_url}"
  fi
}

render_and_apply_argocd_config() {
  local tmp_dir=""
  tmp_dir="$(mktemp -d)"
  ARGOCD_PREVIOUS_CM_FILE="${tmp_dir}/argocd-cm.previous.yaml"
  ARGOCD_PREVIOUS_RBAC_FILE="${tmp_dir}/argocd-rbac-cm.previous.yaml"
  kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o yaml > "${ARGOCD_PREVIOUS_CM_FILE}" 2>/dev/null || true
  kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm -o yaml > "${ARGOCD_PREVIOUS_RBAC_FILE}" 2>/dev/null || true

  sed \
    -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" \
    -e "s|__AUTHENTIK_OIDC_ISSUER__|${AUTHENTIK_OIDC_ISSUER}|g" \
    -e "s|__ARGOCD_OIDC_CLIENT_ID__|${ARGOCD_OIDC_CLIENT_ID}|g" \
    "${REPO_ROOT}/integrations/argocd/argocd-authentik-oidc-cm.yaml.tpl" > "${tmp_dir}/argocd-authentik-oidc-cm.yaml"

  sed \
    -e "s|__ARGOCD_ADMIN_GROUP__|${ARGOCD_ADMIN_GROUP}|g" \
    "${REPO_ROOT}/integrations/argocd/argocd-authentik-rbac-cm.yaml.tpl" > "${tmp_dir}/argocd-authentik-rbac-cm.yaml"

  local previous_oidc=""
  local previous_url=""
  local previous_dex=""
  local next_oidc=""
  local argocd_url="https://argocd.${BASE_DOMAIN}"

  previous_oidc="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.dex\.config}' 2>/dev/null || true)"
  previous_url="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.url}' 2>/dev/null || true)"
  previous_dex="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.oidc\.config}' 2>/dev/null || true)"
  # Render the Dex connector body directly from resolved runtime values.
  # Do not parse the ConfigMap template back into a shell variable: artifact
  # packaging or line-ending differences can make exact text-marker parsing
  # brittle and previously caused false failures such as:
  #   template did not render dex.config
  next_oidc="$(AUTHENTIK_OIDC_ISSUER="${AUTHENTIK_OIDC_ISSUER}" ARGOCD_OIDC_CLIENT_ID="${ARGOCD_OIDC_CLIENT_ID}" python3 - <<'PYCODE'
import os

issuer = os.environ["AUTHENTIK_OIDC_ISSUER"]
client_id = os.environ["ARGOCD_OIDC_CLIENT_ID"]

print(f"""connectors:
  - type: oidc
    id: authentik
    name: Authentik
    config:
      issuer: {issuer}
      clientID: {client_id}
      clientSecret: $dex.authentik.clientSecret
      insecureEnableGroups: true
      getUserInfo: true
      scopes:
        - openid
        - profile
        - email
        - groups
""".rstrip() + "\n")
PYCODE
)"

  [[ -n "${next_oidc}" ]] || die "Rendered Argo CD Dex Authentik config is empty"

  log "Applying Argo CD OIDC config with field-scoped merge patch"
  local cm_patch_payload=""
  cm_patch_payload="$(ARGOCD_URL="${argocd_url}" OIDC_CONFIG="${next_oidc}" python3 - <<'PYCODE'
import json
import os
print(json.dumps({"data": {"url": os.environ["ARGOCD_URL"], "dex.config": os.environ["OIDC_CONFIG"]}}))
PYCODE
)"
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=merge -p "${cm_patch_payload}" >/dev/null

  # CH04.6 uses Argo CD's bundled Dex as the broker for Authentik. Ensure
  # any previous direct oidc.config is removed so the two SSO modes do not
  # compete in the same argocd-cm.
  if [[ -n "${previous_dex}" ]]; then
    log "Removing existing oidc.config because CH04.6 uses Dex-backed Authentik SSO"
    kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=json \
      -p='[{"op":"remove","path":"/data/oidc.config"}]' >/dev/null 2>&1 || true
  fi

  local rbac_apply_output=""
  rbac_apply_output="$(kubectl apply -f "${tmp_dir}/argocd-authentik-rbac-cm.yaml")"
  echo "configmap/argocd-cm field-patched"
  echo "${rbac_apply_output}"

  if [[ "${previous_oidc}" != "${next_oidc}" || "${previous_url}" != "${argocd_url}" || -n "${previous_dex}" ]] \
    || echo "${rbac_apply_output}" | grep -Eq ' configured| created'; then
    ARGOCD_CONFIG_CHANGED=1
  else
    ARGOCD_CONFIG_CHANGED=0
  fi

  print_argocd_oidc_config_summary || true
  # Keep tmp_dir until the rollout path completes so rollback can restore the previous ConfigMaps.
}

print_argocd_oidc_config_summary() {
  log "Current Argo CD OIDC runtime config summary"
  echo "--- argocd-cm data keys ---"
  kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{range $k,$v := .data}{"- "}{$k}{"\n"}{end}' 2>/dev/null || true
  echo "--- dex.config redacted ---"
  kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.dex\.config}' 2>/dev/null \
    | sed -E 's/(clientSecret:[[:space:]]*).*/\1<redacted>/' || true
  if kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.oidc\.config}' 2>/dev/null | grep -q .; then
    echo "WARN: direct oidc.config is still present"
  else
    echo "direct oidc.config: absent"
  fi
  echo
  echo "--- argocd-secret key presence ---"
  if kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.server\.secretkey}' 2>/dev/null | grep -q .; then
    echo "argocd-secret key server.secretkey: present"
  else
    echo "argocd-secret key server.secretkey: MISSING"
  fi
  if kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.dex\.authentik\.clientSecret}' 2>/dev/null | grep -q .; then
    echo "argocd-secret key dex.authentik.clientSecret: present"
  else
    echo "argocd-secret key dex.authentik.clientSecret: MISSING"
  fi
}

restore_previous_argocd_config() {
  # Do not use `kubectl apply` with full live-object backups here. Those
  # backups contain resourceVersion/uid/last-applied metadata and can conflict
  # with a ConfigMap modified by a later reconciliation attempt. Recovery must
  # be conflict-free and field-scoped. The only argocd-cm field introduced by
  # CH04.6-managed SSO fields that can affect argocd-server startup are dex.config
  # and leftover direct oidc.config, so remove those keys explicitly instead
  # of trying to replace the full ConfigMap object.
  log "Restoring Argo CD config with conflict-free field cleanup"
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=json \
    -p='[{"op":"remove","path":"/data/dex.config"}]' >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=json \
    -p='[{"op":"remove","path":"/data/oidc.config"}]' >/dev/null 2>&1 || true

  # RBAC settings do not participate in argocd-server OIDC provider startup.
  # Keep them as-is during emergency recovery to avoid ConfigMap resourceVersion
  # conflicts and unnecessary pod-template churn.
}

remove_argocd_oidc_config_for_recovery() {
  log "Removing Argo CD SSO config for emergency control-plane recovery"
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=json -p='[{"op":"remove","path":"/data/dex.config"}]' >/dev/null 2>&1 || true
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=json -p='[{"op":"remove","path":"/data/oidc.config"}]' >/dev/null 2>&1 || true
}

delete_unhealthy_argocd_server_pods() {
  local bad_pods=""
  bad_pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.phase}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null | awk '$2 != "true" || $4 == "CrashLoopBackOff" {print $1}' || true)"

  if [[ -n "${bad_pods}" ]]; then
    log "Deleting unhealthy argocd-server pods only"
    while IFS= read -r pod_name; do
      [[ -n "${pod_name}" ]] || continue
      kubectl -n "${ARGOCD_NAMESPACE}" delete pod "${pod_name}" --grace-period=0 --force >/dev/null 2>&1 || true
    done <<< "${bad_pods}"
  fi
}

clear_argocd_server_restart_annotation() {
  # Removing the restartedAt annotation mutates the pod template and can create
  # yet another ReplicaSet. Keep this helper only for cases where no stable
  # ReplicaSet revision can be identified. Prefer explicit rollback to the
  # revision that currently has a ready pod.
  log "Clearing argocd-server rollout restart annotation as fallback recovery"
  kubectl -n "${ARGOCD_NAMESPACE}" patch deployment argocd-server --type=json \
    -p='[{"op":"remove","path":"/spec/template/metadata/annotations/kubectl.kubernetes.io~1restartedAt"}]' \
    >/dev/null 2>&1 || true
}

rollback_argocd_server_to_ready_revision() {
  local stable_revision=""

  stable_revision="$(kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk '$3 > 0 && $4 == $3 {print $2}' \
    | sort -n \
    | head -1 || true)"

  if [[ -z "${stable_revision}" ]]; then
    log "No ready argocd-server ReplicaSet revision found for explicit rollback"
    return 1
  fi

  log "Rolling argocd-server back explicitly to ready ReplicaSet revision ${stable_revision}"
  kubectl -n "${ARGOCD_NAMESPACE}" rollout undo deploy/argocd-server --to-revision="${stable_revision}" >/dev/null || return 1
  return 0
}

wait_for_existing_stable_argocd_server() {
  log "Checking whether an existing stable argocd-server pod is still serving the control plane"
  local ready_pods=""
  ready_pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | awk '$2 == "true" {print $1}' || true)"

  if [[ -n "${ready_pods}" ]]; then
    log "Existing ready argocd-server pod detected; treating control-plane availability as preserved"
    return 0
  fi

  return 1
}

scale_down_unready_argocd_replicasets() {
  local bad_rs=""
  bad_rs="$(kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server     -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null | awk '$2 > 0 && ($3 == "" || $3 < $2) {print $1}' || true)"

  if [[ -n "${bad_rs}" ]]; then
    log "Scaling down unready argocd-server ReplicaSets"
    while IFS= read -r rs_name; do
      [[ -n "${rs_name}" ]] || continue
      kubectl -n "${ARGOCD_NAMESPACE}" scale rs "${rs_name}" --replicas=0 >/dev/null 2>&1 || true
    done <<< "${bad_rs}"
  fi
}

diagnose_argocd_server_rollout() {
  log "Collecting Argo CD server rollout diagnostics"
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server -o wide || true
}

collect_argocd_server_crash_logs() {
  log "Collecting Argo CD server crash diagnostics"
  print_argocd_oidc_config_summary || true

  local pod_rows=""
  pod_rows="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
    | awk '$2 != "true" {print "0\t" $0} $2 == "true" {print "1\t" $0}' \
    | sort || true)"

  while IFS=$'\t' read -r _order pod_name ready_state wait_reason; do
    [[ -n "${pod_name:-}" ]] || continue
    if [[ "${ready_state}" != "true" ]]; then
      log "Previous logs for unhealthy ${pod_name} reason=${wait_reason:-unknown}"
      kubectl -n "${ARGOCD_NAMESPACE}" logs "${pod_name}" --previous --tail=240 || true
      log "Current logs for unhealthy ${pod_name} reason=${wait_reason:-unknown}"
      kubectl -n "${ARGOCD_NAMESPACE}" logs "${pod_name}" --tail=240 || true
    else
      log "Current logs for ready ${pod_name} (tail only, to avoid hiding crash logs)"
      kubectl -n "${ARGOCD_NAMESPACE}" logs "${pod_name}" --since=10m --tail=60 || true
    fi
  done <<< "${pod_rows}"

  log "Compact rollout diagnostics"
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get events --sort-by=.lastTimestamp | tail -60 || true
}

repair_argocd_server_rollout() {
  log "Attempting Argo CD server rollout repair"
  diagnose_argocd_server_rollout
  collect_argocd_server_crash_logs || true

  log "Repairing argocd-server by removing bad OIDC config and clearing degraded rollout state"
  restore_previous_argocd_config || true
  remove_argocd_oidc_config_for_recovery || true
  if ! rollback_argocd_server_to_ready_revision; then
    clear_argocd_server_restart_annotation || true
  fi
  scale_down_unready_argocd_replicasets || true
  delete_unhealthy_argocd_server_pods || true

  if kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=90s; then
    log "Argo CD server repair completed"
    return 0
  fi

  if wait_for_existing_stable_argocd_server; then
    log "Argo CD deployment status is still degraded, but a stable server pod remains available after recovery cleanup"
    diagnose_argocd_server_rollout || true
    return 0
  fi

  diagnose_argocd_server_rollout || true
  return 1
}

restart_argocd_server() {
  if [[ "${ARGOCD_CONFIG_CHANGED}" != "1" ]]; then
    log "Argo CD Dex/RBAC config unchanged; skipping unnecessary rollout restart"
    if kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=30s >/dev/null 2>&1; then
      return 0
    fi

    log "Argo CD config is unchanged, but the existing rollout is degraded; running repair path"
    repair_argocd_server_rollout || die "Argo CD server rollout is degraded and repair failed"
    return 0
  fi

  log "Restarting Argo CD Dex server and API server to load changed Authentik connector config"
  if kubectl -n "${ARGOCD_NAMESPACE}" get deploy/argocd-dex-server >/dev/null 2>&1; then
    kubectl -n "${ARGOCD_NAMESPACE}" rollout restart deploy/argocd-dex-server >/dev/null
    kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-dex-server --timeout=180s
  fi
  kubectl -n "${ARGOCD_NAMESPACE}" rollout restart deploy/argocd-server >/dev/null

  if kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=180s; then
    return 0
  fi

  log "Argo CD server rollout failed after changed Dex SSO config; restoring/removing SSO config to protect the control plane"
  collect_argocd_server_crash_logs || true
  restore_previous_argocd_config || true
  remove_argocd_oidc_config_for_recovery || true
  if ! rollback_argocd_server_to_ready_revision; then
    clear_argocd_server_restart_annotation || true
  fi
  scale_down_unready_argocd_replicasets || true
  delete_unhealthy_argocd_server_pods || true
  kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=90s || true
  wait_for_existing_stable_argocd_server || true
  die "Argo CD server failed to start with the reconciled Dex SSO config; SSO config was removed/restored and restart annotation was cleared for recovery"
}

main() {
  ensure_runtime_deps
  ensure_cluster_ready
  validate_prerequisites
  ensure_argocd_server_secretkey
  resolve_or_create_argocd_oidc_secret
  resolve_authentik_api_token
  configure_authentik_argocd_provider
  validate_authentik_oidc_discovery
  validate_authentik_oidc_discovery_from_cluster
  render_and_apply_argocd_config
  restart_argocd_server
  log "Argo CD Dex-backed SSO enabled via Authentik provider slug=${ARGOCD_OIDC_PROVIDER_SLUG} url=https://argocd.${BASE_DOMAIN}"
}

main "$@"
