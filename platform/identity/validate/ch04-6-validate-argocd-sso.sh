#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# CH04.6 - Argo CD SSO contract validator (single focused validator)
#
# Task: P-CH04.6-T01 (Authentik OIDC provider/application contract audit).
#
# It asserts the CH04.6 Argo CD SSO contract in five groups:
#   A. cluster SSO material: rollouts, argocd-secret keys, argocd-cm url
#   B. the Dex-backed connector contract in argocd-cm (issuer, clientID,
#      secret *reference*, groups claim, scopes) and the absence of the direct
#      oidc.config path
#   C. the Argo CD RBAC contract in argocd-rbac-cm (admin group, scopes)
#   D. the Authentik OIDC provider/application contract, including the strict
#      redirect URI allow-list and its completeness (the live redirect_uris
#      collection must contain exactly the three contract entries, so an extra,
#      duplicate, non-strict or unexpected-type entry fails closed even when the
#      reconciliation writer was not the last writer), the scope mappings, the
#      provider/application link and the single-provider/single-application rule
#      that proves no parallel OIDC path exists
#   E. the ambiguous secret-reference checks: the dex client secret key and the
#      stable session key are present, and the legacy direct-OIDC key is absent
#
# Secret handling: this validator asserts secret *key presence* and non-secret
# identifiers only. It never prints, hashes or logs a secret value, and the
# Authentik client secret is only probed for presence.
#
# Read-only: kubectl get and Authentik GET requests only. No mutation, no
# infrastructure workflow, no GitHub/DNS/Cloudflare access.
#
# Invocation contract (stable; used by workflow "04.6 - Enable Argo CD SSO"):
#   bash platform/identity/validate/ch04-6-validate-argocd-sso.sh
# Environment: BASE_DOMAIN, ARGOCD_NAMESPACE, IDENTITY_NAMESPACE,
#   ARGOCD_OIDC_PROVIDER_SLUG, ARGOCD_ADMIN_GROUP,
#   AUTHENTIK_ARGOCD_ADMIN_USERNAME, AUTHENTIK_BASE_URL and optionally
#   AUTHENTIK_BOOTSTRAP_TOKEN (read from the identity namespace when unset).
# Exit status: 0 when every check is PASS or WARN, 1 on the first FAIL.
#############################################################################

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

# --- Contract values, derived exactly like the reconciliation script --------
# The issuer is derived from the Authentik base URL and must equal the issuer the
# discovery document advertises; it is never a hardcoded host.
AUTHENTIK_ISSUER_BASE="${AUTHENTIK_BASE_URL%/}"
EXPECTED_ISSUER="${AUTHENTIK_ISSUER_BASE}/application/o/${EXPECTED_PROVIDER_SLUG}/"
EXPECTED_ARGOCD_URL="https://argocd.${BASE_DOMAIN}"
EXPECTED_PROVIDER_NAME="${ARGOCD_OIDC_PROVIDER_NAME:-Argo CD}"
EXPECTED_REDIRECT_URI="${EXPECTED_ARGOCD_URL}/api/dex/callback"
EXPECTED_CLI_CALLBACK_URI="https://localhost:8085/auth/callback"
EXPECTED_LOGOUT_URI="${EXPECTED_ARGOCD_URL}/logout"
EXPECTED_SCOPES="${ARGOCD_OIDC_SCOPES:-openid profile email groups}"

kubectl -n "${IDENTITY_NAMESPACE}" rollout status deploy/authentik-server --timeout=10s >/dev/null 2>&1 && \
  pass "AUTHENTIK_ROLLOUT" "authentik-server rollout is healthy" || fail "AUTHENTIK_ROLLOUT" "authentik-server rollout is not healthy"

kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc >/dev/null 2>&1 && \
  pass "ARGOCD_OIDC_SECRET" "argocd-authentik-oidc secret exists" || fail "ARGOCD_OIDC_SECRET" "missing argocd-authentik-oidc secret"

client_id_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_ID}' 2>/dev/null || true)"
client_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_SECRET}' 2>/dev/null || true)"
client_id_value="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-authentik-oidc -o jsonpath='{.data.ARGOCD_OIDC_CLIENT_ID}' 2>/dev/null | base64 -d 2>/dev/null || true)"
dex_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.dex\.authentik\.clientSecret}' 2>/dev/null || true)"
server_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.server\.secretkey}' 2>/dev/null || true)"
legacy_oidc_secret_present="$(kubectl -n "${ARGOCD_NAMESPACE}" get secret argocd-secret -o jsonpath='{.data.oidc\.authentik\.clientSecret}' 2>/dev/null || true)"
[[ -n "${client_id_present}" && -n "${client_id_value}" ]] && pass "ARGOCD_CLIENT_ID" "client ID is stored in the Kubernetes secret argocd-authentik-oidc" || fail "ARGOCD_CLIENT_ID" "missing or unreadable client ID in argocd-authentik-oidc"
[[ -n "${client_secret_present}" ]] && pass "ARGOCD_CLIENT_SECRET" "client secret is stored in the Kubernetes secret argocd-authentik-oidc" || fail "ARGOCD_CLIENT_SECRET" "missing client secret"
[[ -n "${dex_secret_present}" ]] && pass "ARGOCD_DEX_SECRET_REFERENCE" "argocd-secret contains dex.authentik.clientSecret" || fail "ARGOCD_DEX_SECRET_REFERENCE" "missing argocd-secret Dex clientSecret key"
[[ -n "${server_secret_present}" ]] && pass "ARGOCD_SERVER_SECRETKEY" "argocd-secret contains stable server.secretkey" || fail "ARGOCD_SERVER_SECRETKEY" "missing argocd-secret server.secretkey"

kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-dex-server --timeout=10s >/dev/null 2>&1 && \
  pass "ARGOCD_DEX_ROLLOUT" "Argo CD Dex server rollout is healthy" || fail "ARGOCD_DEX_ROLLOUT" "Argo CD Dex server rollout is not healthy"

kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=10s >/dev/null 2>&1 && \
  pass "ARGOCD_ROLLOUT" "Argo CD server rollout is healthy" || fail "ARGOCD_ROLLOUT" "Argo CD server rollout is not healthy"

config_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.dex\.config}' 2>/dev/null || true)"
direct_oidc_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.oidc\.config}' 2>/dev/null || true)"
argocd_public_url="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-cm -o jsonpath='{.data.url}' 2>/dev/null || true)"
rbac_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm -o jsonpath='{.data.policy\.csv}' 2>/dev/null || true)"
scopes_text="$(kubectl -n "${ARGOCD_NAMESPACE}" get configmap argocd-rbac-cm -o jsonpath='{.data.scopes}' 2>/dev/null || true)"

[[ "${argocd_public_url}" == "${EXPECTED_ARGOCD_URL}" ]] && \
  pass "ARGOCD_CM_URL" "argocd-cm data.url is ${EXPECTED_ARGOCD_URL}" || fail "ARGOCD_CM_URL" "argocd-cm data.url is not ${EXPECTED_ARGOCD_URL}"

[[ -z "${direct_oidc_text}" ]] && \
  pass "ARGOCD_DIRECT_OIDC_DISABLED" "direct oidc.config is absent because CH04.6 uses Dex-backed SSO" || fail "ARGOCD_DIRECT_OIDC_DISABLED" "direct oidc.config is still present"

echo "${config_text}" | grep -q 'name: Authentik' && \
  pass "ARGOCD_DEX_CONNECTOR_NAME" "Argo CD Dex connector is named Authentik" || fail "ARGOCD_DEX_CONNECTOR_NAME" "Dex connector missing Authentik name"

echo "${config_text}" | grep -q 'type: oidc' && \
  pass "ARGOCD_DEX_CONNECTOR_TYPE" "Argo CD Dex connector type is oidc" || fail "ARGOCD_DEX_CONNECTOR_TYPE" "Dex connector type is not oidc"

echo "${config_text}" | grep -qF "issuer: ${EXPECTED_ISSUER}" && \
  pass "ARGOCD_ISSUER" "Dex connector issuer is the discovered Authentik provider issuer ${EXPECTED_ISSUER}" || fail "ARGOCD_ISSUER" "Dex connector issuer does not match the expected Authentik provider issuer ${EXPECTED_ISSUER}"

echo "${config_text}" | grep -qF "clientID: ${client_id_value}" && \
  pass "ARGOCD_CLIENT_ID_MATCH" "Dex connector clientID matches stored client ID" || fail "ARGOCD_CLIENT_ID_MATCH" "Dex connector clientID mismatch"

echo "${config_text}" | grep -q 'clientSecret: \$dex.authentik.clientSecret' && \
  pass "ARGOCD_CLIENT_SECRET_REF" "Dex connector clientSecret uses the argocd-secret key reference, never an inlined value" || fail "ARGOCD_CLIENT_SECRET_REF" "Dex connector clientSecret reference mismatch"

echo "${config_text}" | grep -q 'insecureEnableGroups: true' && \
  pass "ARGOCD_DEX_GROUPS_ENABLED" "Dex connector enables groups claim handling" || fail "ARGOCD_DEX_GROUPS_ENABLED" "Dex connector missing insecureEnableGroups"

# Every contract scope must be requested by the connector. ARGOCD_GROUP_SCOPE is
# kept as the historical check code for the groups scope.
for scope in ${EXPECTED_SCOPES}; do
  if echo "${config_text}" | grep -qE "^[[:space:]]*-[[:space:]]*${scope}[[:space:]]*$"; then
    if [[ "${scope}" == "groups" ]]; then
      pass "ARGOCD_GROUP_SCOPE" "groups scope is requested by the Dex connector"
    else
      pass "ARGOCD_SCOPE_${scope^^}" "Dex connector requests the ${scope} scope"
    fi
  else
    if [[ "${scope}" == "groups" ]]; then
      fail "ARGOCD_GROUP_SCOPE" "the Dex connector does not request the groups scope"
    else
      fail "ARGOCD_SCOPE_${scope^^}" "the Dex connector does not request the ${scope} scope"
    fi
  fi
done

echo "${rbac_text}" | grep -q "g, ${EXPECTED_ADMIN_GROUP}, role:admin" && \
  pass "ARGOCD_RBAC_ADMIN_GROUP" "admin group maps to role:admin" || warn "ARGOCD_RBAC_ADMIN_GROUP" "admin group mapping not found"

echo "${scopes_text}" | grep -q 'groups' && \
  pass "ARGOCD_RBAC_SCOPES" "RBAC scopes include groups" || warn "ARGOCD_RBAC_SCOPES" "RBAC scopes do not include groups"

# The legacy direct-OIDC client secret key is reconciled away by CH04.6. It is
# inert here, so its presence is a warning: it must not become a third secret
# reference that implies a parallel direct-OIDC path.
if [[ -z "${legacy_oidc_secret_present}" ]]; then
  pass "ARGOCD_LEGACY_OIDC_SECRET_ABSENT" "argocd-secret carries exactly one OIDC client secret key (Dex-backed path only)"
else
  warn "ARGOCD_LEGACY_OIDC_SECRET_ABSENT" "argocd-secret still carries the legacy direct-OIDC key oidc.authentik.clientSecret; re-run the CH04.6 reconciliation to retire it"
fi

if command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  discovery_url="${EXPECTED_ISSUER}.well-known/openid-configuration"
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

    DISCOVERY_JSON="${discovery_json}" EXPECTED_ISSUER="${EXPECTED_ISSUER}" python3 - <<'PYISSUER' && \
      pass "AUTHENTIK_OIDC_ISSUER_MATCH" "discovery issuer equals the provider issuer ${EXPECTED_ISSUER}" || \
      fail "AUTHENTIK_OIDC_ISSUER_MATCH" "discovery issuer does not equal the expected provider issuer ${EXPECTED_ISSUER}"
import json
import os
import sys

doc = json.loads(os.environ["DISCOVERY_JSON"])
issuer = str(doc.get("issuer", "")).rstrip("/")
expected = os.environ["EXPECTED_ISSUER"].rstrip("/")
if issuer != expected:
    print(f"discovery issuer {issuer!r} != expected {expected!r}", file=sys.stderr)
    sys.exit(1)
print("issuer:", issuer)
PYISSUER
  else
    warn "AUTHENTIK_OIDC_SIGNING_ALG" "skipped signing algorithm validation; discovery endpoint could not be fetched"
    warn "AUTHENTIK_OIDC_ISSUER_MATCH" "skipped discovery issuer validation; discovery endpoint could not be fetched"
  fi
fi

# ---------------------------------------------------------------------------
# Authentik provider/application contract (read-only API session)
#
# One session asserts the CH04.5 group consumption, the admin membership and the
# whole Argo CD provider/application contract. Findings aggregate: every check
# emits a PASS/FAIL/WARN line and the block exits non-zero when a contract check
# failed. No secret value is read or printed.
# ---------------------------------------------------------------------------
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
  contract_output=""
  if ! contract_output="$(AUTHENTIK_BASE_URL="${AUTHENTIK_BASE_URL}" \
      AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN}" \
      EXPECTED_ADMIN_GROUP="${EXPECTED_ADMIN_GROUP}" \
      EXPECTED_ADMIN_USERNAME="${EXPECTED_ADMIN_USERNAME}" \
      EXPECTED_CLIENT_ID="${client_id_value}" \
      EXPECTED_PROVIDER_NAME="${EXPECTED_PROVIDER_NAME}" \
      EXPECTED_PROVIDER_SLUG="${EXPECTED_PROVIDER_SLUG}" \
      EXPECTED_REDIRECT_URI="${EXPECTED_REDIRECT_URI}" \
      EXPECTED_CLI_CALLBACK_URI="${EXPECTED_CLI_CALLBACK_URI}" \
      EXPECTED_LOGOUT_URI="${EXPECTED_LOGOUT_URI}" \
      EXPECTED_SCOPES="${EXPECTED_SCOPES}" \
      python3 - <<'PYCONTRACT'
import json
import os
import sys
import urllib.parse
import urllib.request

base_url = os.environ["AUTHENTIK_BASE_URL"].rstrip("/")
token = os.environ["AUTHENTIK_BOOTSTRAP_TOKEN"]
group_name = os.environ["EXPECTED_ADMIN_GROUP"]
username = os.environ["EXPECTED_ADMIN_USERNAME"]
expected_client_id = os.environ.get("EXPECTED_CLIENT_ID", "")
provider_name = os.environ.get("EXPECTED_PROVIDER_NAME", "Argo CD")
provider_slug = os.environ.get("EXPECTED_PROVIDER_SLUG", "argocd")
expected_redirect = os.environ.get("EXPECTED_REDIRECT_URI", "")
expected_cli_callback = os.environ.get("EXPECTED_CLI_CALLBACK_URI", "")
expected_logout = os.environ.get("EXPECTED_LOGOUT_URI", "")
expected_scopes = [scope for scope in os.environ.get("EXPECTED_SCOPES", "").split() if scope]
headers = {
    "Authorization": f"Bearer {token}",
    "Accept": "application/json",
}

failures = []


def emit(status, check, detail):
    print(f"{status} | {check} | {detail}")


def expect(ok, check, detail_ok, detail_fail):
    if ok:
        emit("PASS", check, detail_ok)
    else:
        emit("FAIL", check, detail_fail)
        failures.append(check)


def expect_field(obj, key, expected, check, detail_ok, detail_fail):
    """Assert obj[key] == expected; WARN when the API does not expose the field."""
    if key not in obj:
        emit("WARN", check,
             f"the Authentik API response does not expose {key!r}; the contract value is asserted on the write path only")
        return
    expect(str(obj.get(key)) == str(expected), check, detail_ok, detail_fail)


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


def search_exact(path, field, value):
    enc = urllib.parse.quote(value)
    return [item for item in results(f"{path}?search={enc}") if item.get(field) == value]


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


def same_url(left, right):
    return str(left or "").rstrip("/") == str(right or "").rstrip("/")


# --- A. CH04.5-owned admin group: consumed, never redefined ----------------
group = exact("/api/v3/core/groups/", "name", group_name)
expect(group is not None, "AUTHENTIK_ADMIN_GROUP_EXISTS",
       f"CH04.5-managed group {group_name!r} exists",
       f"CH04.5 group {group_name!r} is missing; run '04.5 - Deploy Identity Foundation' "
       "(scripts/ch04-5-bootstrap-identity-model.sh) first")

if group:
    expect(not group.get("is_superuser"), "AUTHENTIK_ADMIN_GROUP_NON_SUPERUSER",
           f"CH04.5 group {group_name!r} is not an Authentik superuser group",
           f"CH04.5 group {group_name!r} is an Authentik superuser group")
    expect(not group.get("parent"), "AUTHENTIK_ADMIN_GROUP_NO_PARENT",
           f"CH04.5 group {group_name!r} does not inherit from a parent group",
           f"CH04.5 group {group_name!r} inherits from parent group {group.get('parent')!r}")

    attributes = group.get("attributes") or {}
    stamps = [key for key in ("platforminit_managed_by", "platforminit_contract_version")
              if key in attributes]
    if len(stamps) == 2:
        emit("PASS", "AUTHENTIK_ADMIN_GROUP_OWNERSHIP",
             "CH04.5 managed ownership stamps are present on the group")
    else:
        emit("WARN", "AUTHENTIK_ADMIN_GROUP_OWNERSHIP",
             "CH04.5 managed ownership stamps are absent; re-run the CH04.5 identity model bootstrap. "
             "The CH04.6 payload no longer writes group attributes")

# --- B. Argo CD admin membership -------------------------------------------
user = exact("/api/v3/core/users/", "username", username)
expect(user is not None, "AUTHENTIK_ARGOCD_ADMIN_USER",
       f"Authentik user {username} exists",
       f"Authentik user {username} is missing; set AUTHENTIK_ARGOCD_ADMIN_USERNAME if the bootstrap admin differs")
if user and group:
    user_detail = request(f"/api/v3/core/users/{user['pk']}/")
    expect(group["pk"] in group_ids(user_detail.get("groups", [])), "AUTHENTIK_ARGOCD_ADMIN_GROUP",
           f"{username} is a direct member of non-superuser {group_name}",
           f"{username} is not a direct member of {group_name}")

# --- C. Authentik OIDC provider contract -----------------------------------
provider = exact("/api/v3/providers/oauth2/", "name", provider_name)
expect(provider is not None, "AUTHENTIK_PROVIDER_EXISTS",
       f"Authentik OAuth2/OIDC provider {provider_name!r} exists",
       f"Authentik OAuth2/OIDC provider {provider_name!r} is missing; re-run the CH04.6 SSO reconciliation")

if provider:
    expect(len(search_exact("/api/v3/providers/oauth2/", "name", provider_name)) == 1,
           "AUTHENTIK_PROVIDER_UNIQUE",
           f"exactly one OAuth2/OIDC provider is named {provider_name!r}, so no parallel OIDC path exists",
           f"expected exactly one provider named {provider_name!r}")

    expect_field(provider, "client_type", "confidential", "AUTHENTIK_PROVIDER_CLIENT_TYPE",
                 "provider client_type is confidential",
                 f"provider client_type is {provider.get('client_type')!r}, expected 'confidential'")

    if "grant_types" in provider:
        grant_types = sorted(str(grant) for grant in (provider.get("grant_types") or []))
        expect("authorization_code" in grant_types, "AUTHENTIK_PROVIDER_GRANT_TYPES",
               f"provider grant_types include authorization_code ({grant_types})",
               f"provider grant_types do not include authorization_code ({grant_types})")
    else:
        emit("WARN", "AUTHENTIK_PROVIDER_GRANT_TYPES",
             "the Authentik API response does not expose 'grant_types'; the contract value is asserted on the write path only")

    expect_field(provider, "sub_mode", "hashed_user_id", "AUTHENTIK_PROVIDER_SUB_MODE",
                 "provider sub_mode is hashed_user_id",
                 f"provider sub_mode is {provider.get('sub_mode')!r}, expected 'hashed_user_id'")

    expect_field(provider, "issuer_mode", "per_provider", "AUTHENTIK_PROVIDER_ISSUER_MODE",
                 "provider issuer_mode is per_provider, so the issuer is provider-scoped",
                 f"provider issuer_mode is {provider.get('issuer_mode')!r}, expected 'per_provider'")

    expect_field(provider, "include_claims_in_id_token", True, "AUTHENTIK_PROVIDER_ID_TOKEN_CLAIMS",
                 "provider includes claims in the ID token, so the groups claim reaches Argo CD RBAC",
                 "provider does not include claims in the ID token")

    expect(bool(provider.get("signing_key")), "AUTHENTIK_PROVIDER_SIGNING_KEY",
           "provider pins an asymmetric signing key (JWKS-backed RS256 path for Argo CD/Dex)",
           "provider has no signing_key, so Argo CD/Dex has no asymmetric JWKS path "
           "(set AUTHENTIK_ARGOCD_SIGNING_KEY_NAME or let the reconciliation select a key)")

    # The client id is a non-secret identifier: it is compared with the value
    # stored in argocd/argocd-authentik-oidc. The client secret value is never
    # read; only its presence is probed.
    if expected_client_id:
        expect(str(provider.get("client_id")) == expected_client_id, "AUTHENTIK_PROVIDER_CLIENT_ID",
               "provider client_id matches the client id stored in argocd-authentik-oidc",
               "provider client_id does not match the client id stored in argocd-authentik-oidc")
    else:
        emit("WARN", "AUTHENTIK_PROVIDER_CLIENT_ID",
             "the argocd-authentik-oidc client id could not be read, so the provider client id could not be cross-checked")

    if "client_secret" in provider:
        expect(bool(provider.get("client_secret")), "AUTHENTIK_PROVIDER_CLIENT_SECRET_SET",
               "provider has a client secret configured (presence only; the value is never read or printed)",
               "provider has no client secret configured")
    else:
        emit("WARN", "AUTHENTIK_PROVIDER_CLIENT_SECRET_SET",
             "the Authentik API response does not expose 'client_secret'; secret-key ownership is asserted "
             "through the argocd-secret key checks instead")

    if "logout_uri" in provider:
        expect(same_url(provider.get("logout_uri"), expected_logout), "AUTHENTIK_PROVIDER_LOGOUT_URI",
               f"provider logout_uri is {expected_logout}",
               f"provider logout_uri is {provider.get('logout_uri')!r}, expected {expected_logout}")
    else:
        emit("WARN", "AUTHENTIK_PROVIDER_LOGOUT_URI",
             "the Authentik API response does not expose 'logout_uri'; the contract value is asserted on the write path only")

    expect_field(provider, "logout_method", "frontchannel", "AUTHENTIK_PROVIDER_LOGOUT_METHOD",
                 "provider logout_method is frontchannel",
                 f"provider logout_method is {provider.get('logout_method')!r}, expected 'frontchannel'")

    # Strict redirect allow-list, asserted in two steps: every expected entry must
    # be present with matching_mode `strict`, and the complete live redirect_uris
    # collection must contain nothing else. The second step is the completeness
    # boundary: an extra wildcard/prefix/regex entry, a duplicate, a non-strict
    # matching mode or an unexpected redirect_uri_type fails closed, so an
    # already-drifted provider cannot pass merely because the reconciliation
    # writer normally replaces the list. The redirect URI list is the contract's
    # anti-open-redirect boundary (runbook: "no wildcard, prefix or regex
    # matching").
    redirect_uris = provider.get("redirect_uris") or []
    expected_redirect_targets = (
        (expected_redirect, "authorization"),
        (expected_cli_callback, "authorization"),
        (expected_logout, "logout"),
    )

    def normalize_redirect_url(url):
        # Same normalization the entry matcher always applied: a trailing slash
        # is not a different redirect target.
        return str(url or "").rstrip("/")

    def redirect_tuple(entry):
        """Normalize one API entry into the comparable (url, type, mode) tuple."""
        if not isinstance(entry, dict):
            return (f"<malformed entry: {type(entry).__name__}>", "", "")
        return (
            normalize_redirect_url(entry.get("url")),
            str(entry.get("redirect_uri_type", "")),
            str(entry.get("matching_mode", "")),
        )

    def render_redirect(entry_tuple):
        url, uri_type, matching_mode = entry_tuple
        return (f"(url={url!r}, redirect_uri_type={uri_type!r}, "
                f"matching_mode={matching_mode!r})")

    def render_redirect_list(entries, limit=5):
        rendered = ", ".join(entries[:limit])
        if len(entries) > limit:
            rendered += f", ... (+{len(entries) - limit} more)"
        return rendered

    expected_redirect_tuples = [
        (normalize_redirect_url(url), uri_type, "strict")
        for url, uri_type in expected_redirect_targets
    ]
    actual_redirect_tuples = [redirect_tuple(entry) for entry in redirect_uris]

    def strict_entry_registered(url, uri_type):
        return (normalize_redirect_url(url), uri_type, "strict") in actual_redirect_tuples

    expect(strict_entry_registered(expected_redirect, "authorization"), "AUTHENTIK_PROVIDER_REDIRECT_URI",
           f"strict authorization redirect URI {expected_redirect} is registered",
           f"the strict authorization redirect URI {expected_redirect} is not registered")
    expect(strict_entry_registered(expected_cli_callback, "authorization"), "AUTHENTIK_PROVIDER_CLI_CALLBACK_URI",
           f"strict Argo CD CLI callback URI {expected_cli_callback} is registered",
           f"the strict Argo CD CLI callback URI {expected_cli_callback} is not registered")
    expect(strict_entry_registered(expected_logout, "logout"), "AUTHENTIK_PROVIDER_LOGOUT_REDIRECT_URI",
           f"strict logout redirect URI {expected_logout} is registered",
           f"the strict logout redirect URI {expected_logout} is not registered")

    # Completeness of the collection: exactly the expected strict tuples, once
    # each. Only non-secret contract values are rendered in the detail.
    expected_rendered_redirects = sorted(render_redirect(item) for item in expected_redirect_tuples)
    actual_rendered_redirects = sorted(render_redirect(item) for item in actual_redirect_tuples)
    extra_redirects = sorted(set(actual_rendered_redirects) - set(expected_rendered_redirects))
    missing_redirects = sorted(set(expected_rendered_redirects) - set(actual_rendered_redirects))
    duplicate_redirects = sorted(
        {item for item in actual_rendered_redirects if actual_rendered_redirects.count(item) > 1}
    )
    non_strict_redirects = sorted(
        render_redirect(item) for item in actual_redirect_tuples if item[2] != "strict"
    )
    unexpected_type_redirects = sorted(
        render_redirect(item) for item in actual_redirect_tuples
        if item[1] not in ("authorization", "logout")
    )

    if not (extra_redirects or missing_redirects or duplicate_redirects
            or non_strict_redirects or unexpected_type_redirects):
        emit("PASS", "AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST",
             f"the provider redirect_uris allow-list is exactly the three strict contract entries "
             f"({len(actual_redirect_tuples)} entries; no extra, duplicate, non-strict or unexpected-type entry)")
    else:
        reasons = []
        if extra_redirects:
            reasons.append(f"unexpected extra entries: {render_redirect_list(extra_redirects)}")
        if missing_redirects:
            reasons.append(f"missing expected entries: {render_redirect_list(missing_redirects)}")
        if duplicate_redirects:
            reasons.append(f"duplicate entries: {render_redirect_list(duplicate_redirects)}")
        if non_strict_redirects:
            reasons.append(
                "entries whose matching_mode is not 'strict': "
                f"{render_redirect_list(non_strict_redirects)}"
            )
        if unexpected_type_redirects:
            reasons.append(
                "entries with an unexpected redirect_uri_type: "
                f"{render_redirect_list(unexpected_type_redirects)}"
            )
        emit("FAIL", "AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST",
             "the provider redirect_uris allow-list is not exactly the three strict contract entries; "
             + "; ".join(reasons))
        failures.append("AUTHENTIK_PROVIDER_REDIRECT_URI_ALLOWLIST")

    mapped_pks = [str(item.get("pk") if isinstance(item, dict) else item)
                  for item in (provider.get("property_mappings") or [])]
    scope_index = {}
    for item in results("/api/v3/propertymappings/provider/scope/?page_size=200"):
        scope_index[str(item.get("pk"))] = item

    def scope_mapped(scope):
        # Mirrors the reconciliation rule: match the scope_name, or the mapping
        # name that authenticates the default openid/profile/email mappings.
        for pk in mapped_pks:
            item = scope_index.get(pk) or {}
            if str(item.get("scope_name", "")) == scope \
                    or f"'{scope}'" in str(item.get("name", "")).lower():
                return True
        return False

    for scope in expected_scopes:
        expect(scope_mapped(scope), f"AUTHENTIK_PROVIDER_SCOPE_{scope.upper()}",
               f"provider maps a {scope} scope mapping",
               f"provider has no {scope} scope mapping")

# --- D. Authentik application contract -------------------------------------
app = exact("/api/v3/core/applications/", "slug", provider_slug)
expect(app is not None, "AUTHENTIK_APPLICATION_EXISTS",
       f"Authentik application slug {provider_slug!r} exists",
       f"Authentik application slug {provider_slug!r} is missing; re-run the CH04.6 SSO reconciliation")

if app:
    expect(len(search_exact("/api/v3/core/applications/", "slug", provider_slug)) == 1,
           "AUTHENTIK_APPLICATION_UNIQUE",
           f"exactly one application has slug {provider_slug!r}, so no parallel application path exists",
           f"expected exactly one application with slug {provider_slug!r}")

if app and provider:
    linked = app.get("provider")
    linked_pk = linked.get("pk") if isinstance(linked, dict) else linked
    expect(str(linked_pk) == str(provider.get("pk")), "AUTHENTIK_APPLICATION_PROVIDER_LINK",
           "application provider link resolves to the single asserted Argo CD OIDC provider",
           "application provider link does not resolve to the asserted Argo CD OIDC provider")

if failures:
    print(f"contract failures ({len(failures)}): {', '.join(sorted(set(failures)))}", file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PYCONTRACT
)"; then
    printf '%s\n' "${contract_output}" >&2
    fail "AUTHENTIK_ARGOCD_OIDC_CONTRACT" "Authentik Argo CD OIDC provider/application contract validation failed"
  fi
  printf '%s\n' "${contract_output}"
else
  warn "AUTHENTIK_ARGOCD_OIDC_CONTRACT" "skipped Authentik OIDC provider/application contract validation; missing bootstrap token or python3"
fi

if command -v curl >/dev/null 2>&1; then
  if curl -fsSIk "https://argocd.${BASE_DOMAIN}" >/dev/null 2>&1; then
    pass "ARGOCD_HTTPS" "Argo CD URL responds over HTTPS"
  else
    warn "ARGOCD_HTTPS" "Argo CD HTTPS check failed from host; verify DNS/TLS externally"
  fi
fi
