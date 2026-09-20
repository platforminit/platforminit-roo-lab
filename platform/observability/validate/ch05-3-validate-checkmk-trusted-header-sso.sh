#!/usr/bin/env bash
set -euo pipefail
# Modes:
#   runtime (default) - read-only assertions against the live Checkmk operations stack.
#   static            - repository-contract assertions for the Authentik -> Traefik -> auth-shim
#                       consumer boundary. Performs no cluster access and no runtime mutation:
#   CH05_SSO_VALIDATE_MODE=static bash platform/observability/validate/ch05-3-validate-checkmk-trusted-header-sso.sh
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
export KUBECONFIG

# --- Static consumer-boundary contract (no cluster access, no runtime mutation) ---
VALIDATE_MODE="${CH05_SSO_VALIDATE_MODE:-runtime}"
VALIDATOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${CH05_SSO_REPO_ROOT:-$(cd "${VALIDATOR_DIR}/../../.." && pwd)}"
CANONICAL_OPERATIONS_GROUP="${CANONICAL_OPERATIONS_GROUP:-PlatformInit Operations}"
CANONICAL_OPERATIONS_GROUP_SLUG="${CANONICAL_OPERATIONS_GROUP_SLUG:-platforminit-operations}"
RETIRED_OPERATIONS_GROUPS=("Zabbix Admins" "OpenObserve Admins")
ENABLE_SCRIPT_REL="platform/observability/scripts/ch05-3-enable-checkmk-trusted-header-sso.sh"
IDENTITY_MODEL_REL="platform/identity/groups/platforminit-groups.yaml"
INGRESS_MANIFEST_REL="platform/observability/manifests/templates/checkmk/checkmk-ingress.yaml"
SHIM_MANIFEST_REL="platform/observability/manifests/templates/checkmk/checkmk-config.yaml"

static_validate(){
  local rel path
  for rel in "$ENABLE_SCRIPT_REL" "$IDENTITY_MODEL_REL" "$INGRESS_MANIFEST_REL" "$SHIM_MANIFEST_REL"; do
    path="${REPO_ROOT}/${rel}"
    [[ -f "$path" ]] || die "Static contract file is missing: $path (set CH05_SSO_REPO_ROOT to the repository root)"
  done
  local enable_script="${REPO_ROOT}/${ENABLE_SCRIPT_REL}"
  local identity_model="${REPO_ROOT}/${IDENTITY_MODEL_REL}"
  local ingress_manifest="${REPO_ROOT}/${INGRESS_MANIFEST_REL}"
  local shim_manifest="${REPO_ROOT}/${SHIM_MANIFEST_REL}"

  # 1) CH04.5 owns the canonical operations identity definition; CH05 must not define a second one.
  python3 - "$identity_model" "$CANONICAL_OPERATIONS_GROUP" "$CANONICAL_OPERATIONS_GROUP_SLUG" "${RETIRED_OPERATIONS_GROUPS[@]}" <<'PY_IDENTITY'
import json, sys
model_path, canonical_name, canonical_slug = sys.argv[1], sys.argv[2], sys.argv[3]
retired = tuple(sys.argv[4:])
with open(model_path, encoding='utf-8') as handle:
    raw = handle.read()
data = json.loads(raw)
mgmt = data.get('management', {}) or {}
groups = data.get('groups', []) or []
fail = []
def expect(condition, message):
    if not condition:
        fail.append(message)
expect(mgmt.get('managed_by') == 'ch04-5-bootstrap-identity-model', "identity model managed_by is not ch04-5-bootstrap-identity-model")
expect(mgmt.get('owner_chapter') == 'CH04.5', "identity model owner_chapter is not CH04.5")
expect(mgmt.get('reconcile_mode') == 'upsert-no-prune', "identity model reconcile_mode is not upsert-no-prune")
expect(str(mgmt.get('reconciler', '')).endswith('ch04-5-bootstrap-identity-model.sh'), "identity model reconciler is not the CH04.5 reconciler")
ops = [g for g in groups if str(g.get('slug')) == canonical_slug]
expect(len(ops) == 1, f"expected exactly one group with slug {canonical_slug!r}, found {len(ops)}")
if len(ops) == 1:
    group = ops[0]
    expect(group.get('name') == canonical_name, f"canonical operations group name is {group.get('name')!r}, expected {canonical_name!r}")
    expect(group.get('consumer_chapter') == 'CH05', "canonical operations group consumer_chapter is not CH05")
    expect(group.get('owner_chapter') == 'CH04.5', "canonical operations group owner_chapter is not CH04.5")
    expect(group.get('scope') == 'application:operations', "canonical operations group scope is not application:operations")
    expect(group.get('is_superuser') is False, "canonical operations group must not be a superuser group")
expect(len([g for g in groups if g.get('scope') == 'application:operations']) == 1, "more than one application:operations group exists in the identity model")
present = [name for name in retired if any(str(g.get('name')) == name for g in groups)]
expect(not present, f"retired desired-state group present in the identity model: {present}")
for name in retired:
    expect(name not in raw, f"retired identity {name!r} is referenced in the identity model")
if fail:
    for item in fail:
        print(f"FATAL: static identity-ownership check failed: {item}", file=sys.stderr)
    sys.exit(1)
print(f"PASS: CH04.5 owns the canonical operations group {canonical_name!r} ({canonical_slug}) consumed by CH05")
print("PASS: retired Zabbix/OpenObserve desired-state groups are absent from the canonical identity model")
PY_IDENTITY

  # 2) CH05 consumer contract: resolve the canonical group, never create or re-attribute groups.
  grep -Fq "$CANONICAL_OPERATIONS_GROUP" "$enable_script" \
    || die "CH05.3 SSO enable script does not consume the canonical operations group ${CANONICAL_OPERATIONS_GROUP}"
  grep -Fq 'require_group(' "$enable_script" \
    || die "CH05.3 SSO enable script must resolve the canonical operations group (require_group) instead of reconciling it"
  if grep -Eq "ensure_group\(|'POST'[[:space:]]*,[[:space:]]*'/api/v3/core/groups/'|'PATCH'[^,]*,[[:space:]]*f?\"/api/v3/core/groups/" "$enable_script"; then
    die "CH05.3 SSO enable script still creates or patches Authentik groups; CH04.5 owns the group definition"
  fi
  grep -Fq 'RETIRED_OPERATIONS_GROUPS' "$enable_script" \
    || die "CH05.3 SSO enable script has no guard against retired operations identities"
  # Retired stack names are allowed only inside the declared retired-identity guard, so a mention
  # outside that guard means the SSO path actually depends on a retired operations identity.
  local stale
  stale="$(grep -Ein 'zabbix|openobserve' "$enable_script" | grep -viE "RETIRED_OPERATIONS_GROUPS|Refusing to reconcile retired" || true)"
  [[ -z "$stale" ]] || die "CH05.3 SSO enable script depends on retired operations identities: ${stale}"
  grep -Fq '"internal_host":"http://checkmk.operations.svc.cluster.local"' "$enable_script" \
    || die "CH05.3 Authentik proxy provider does not target the in-cluster Checkmk service"
  printf '%s\n' "PASS: CH05.3 consumes the canonical operations group by lookup only and creates no Authentik group"
  printf '%s\n' "PASS: CH05.3 SSO path defines no Zabbix/OpenObserve identity and guards retired operations groups"

  # 3) Authentik -> Traefik -> auth-shim consumer boundary from the Argo CD-owned manifests.
  grep -Fq 'name: authentik-forward-auth' "$ingress_manifest" \
    || die "CH05 ingress manifest has no operations-local Authentik forwardAuth service"
  grep -Fq 'externalName: {{ .Values.authentik.embeddedOutpostService }}.{{ .Values.authentik.namespace }}.svc.cluster.local' "$ingress_manifest" \
    || die "CH05 Authentik forwardAuth service is not an ExternalName service into the identity namespace"
  grep -Fq 'name: checkmk-authentik-forward-auth' "$ingress_manifest" \
    || die "CH05 ingress manifest has no checkmk-authentik-forward-auth middleware"
  grep -Fq 'address: "http://authentik-forward-auth.operations.svc.cluster.local' "$ingress_manifest" \
    || die "CH05 forwardAuth middleware does not target the operations-local Authentik forwardAuth service"
  grep -Fq '/outpost.goauthentik.io/auth/traefik' "$ingress_manifest" \
    || die "CH05 forwardAuth middleware does not target the Authentik outpost auth endpoint"
  grep -Fq 'X-authentik-username' "$ingress_manifest" \
    || die "CH05 forwardAuth middleware does not forward the Authentik username header to the consumer"
  [[ "$(grep -Fc 'checkmk-authentik-forward-auth' "$ingress_manifest")" -ge 2 ]] \
    || die "CH05 IngressRoute does not reference the checkmk-authentik-forward-auth middleware"
  grep -Eq 'proxy_set_header[[:space:]]+X-Remote-User[[:space:]]+cmkadmin;' "$shim_manifest" \
    || die "CH05 auth-shim manifest does not map approved Authentik sessions to the deterministic Checkmk user"
  grep -Eq 'proxy_set_header[[:space:]]+X-Remote-Original-User[[:space:]]+\$http_x_authentik_username;' "$shim_manifest" \
    || die "CH05 auth-shim manifest does not preserve the original Authentik username"
  grep -Eq 'proxy_pass_request_headers[[:space:]]+off;' "$shim_manifest" \
    || die "CH05 auth-shim manifest does not strip unapproved browser/Authentik headers"
  printf '%s\n' "PASS: Traefik forwardAuth targets the operations-local Authentik outpost service and forwards the Authentik username"
  printf '%s\n' "PASS: auth-shim consumes only the approved Authentik session and maps it to the deterministic Checkmk principal"
}

if [[ "$VALIDATE_MODE" == "static" ]]; then
  log "Static contract mode: proving the Authentik -> Traefik -> auth-shim consumer boundary without cluster access or runtime mutation"
  static_validate
  echo "PASS: static CH05 Checkmk SSO consumer-boundary contract holds (no runtime mutation)"
  exit 0
fi
[[ "$VALIDATE_MODE" == "runtime" ]] || die "Unsupported CH05_SSO_VALIDATE_MODE=${VALIDATE_MODE}; expected 'static' or 'runtime'"

[[ -n "$BASE_DOMAIN" ]] || die "Missing BASE_DOMAIN"
kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth >/dev/null || die "Missing Checkmk Authentik forwardAuth middleware"
kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-logout-redirect >/dev/null || die "Missing Checkmk Authentik logout redirect middleware"
kubectl -n "$NAMESPACE" get ingressroute.traefik.io checkmk >/dev/null || die "Missing Checkmk IngressRoute"
kubectl -n "$NAMESPACE" get secret checkmk-sso >/dev/null || die "Missing checkmk-sso secret"

kubectl -n "$NAMESPACE" get service authentik-forward-auth >/dev/null || die "Missing operations-local ExternalName service for Authentik forwardAuth"
checksum_annotation="$(kubectl -n "$NAMESPACE" get deployment checkmk -o go-template='{{ index .spec.template.metadata.annotations "checksum/auth-shim-config" }}' 2>/dev/null || true)"
[[ -n "$checksum_annotation" ]] || die "Checkmk Deployment lacks checksum/auth-shim-config; auth-shim nginx can keep stale subPath-mounted ConfigMap content"

external_name="$(kubectl -n "$NAMESPACE" get service authentik-forward-auth -o jsonpath='{.spec.externalName}')"
case "$external_name" in
  authentik-server.*.svc.cluster.local) ;;
  *) die "Unexpected Authentik forwardAuth ExternalName: $external_name" ;;
esac
addr="$(kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth -o jsonpath='{.spec.forwardAuth.address}')"
case "$addr" in
  *authentik-forward-auth.operations.svc.cluster.local*/outpost.goauthentik.io/auth/traefik*) ;;
  *) die "Checkmk middleware does not point to the operations-local Authentik forwardAuth endpoint: $addr" ;;
esac
ingress_yaml="$(kubectl -n "$NAMESPACE" get ingressroute.traefik.io checkmk -o yaml)"
printf '%s\n' "$ingress_yaml" | grep -q 'checkmk-authentik-forward-auth' || die "Checkmk IngressRoute is not protected by Authentik middleware"
printf '%s\n' "$ingress_yaml" | grep -q 'checkmk-authentik-logout-redirect' || die "Checkmk IngressRoute does not route native Checkmk logout through Authentik global logout flow"
printf '%s\n' "$ingress_yaml" | grep -q 'Path(`/cmk/check_mk/logout.py`)' || die "Checkmk IngressRoute does not have the native Checkmk logout path"
printf '%s\n' "$ingress_yaml" | grep -q 'Path(`/cmk/logout.py`)' || die "Checkmk IngressRoute does not have the alternate Checkmk logout path"
kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth -o yaml | grep -qi 'X-authentik-username' || die "Checkmk forwardAuth middleware does not forward X-authentik-username"
logout_redirect_yaml="$(kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-logout-redirect -o yaml)"
printf '%s\n' "$logout_redirect_yaml" | grep -q 'https://auth\.' || die "Checkmk logout redirect middleware must target the Authentik public host, not the Checkmk host"
printf '%s\n' "$logout_redirect_yaml" | grep -q '/if/flow/default-invalidation-flow/' || die "Checkmk logout redirect middleware does not target Authentik global logout flow"
printf '%s\n' "$logout_redirect_yaml" | grep -q 'permanent: false' || die "Checkmk logout redirect must be temporary, not permanent"

shim_conf="$(kubectl -n "$NAMESPACE" get configmap checkmk-nginx-auth-shim -o jsonpath='{.data.default\.conf}')"
[[ -n "$shim_conf" ]] || die "Checkmk auth shim ConfigMap does not contain default.conf"

if ! printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-User[[:space:]]+cmkadmin;'; then
  printf '%s\n' "=== checkmk-nginx-auth-shim default.conf ===" >&2
  printf '%s\n' "$shim_conf" >&2
  die "Checkmk auth shim does not map approved Authentik sessions to deterministic Checkmk user cmkadmin"
fi
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_pass_request_headers[[:space:]]+off;' \
  || die "Checkmk auth shim still forwards all browser/Authentik headers"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Content-Type[[:space:]]+\$content_type;' \
  || die "Checkmk auth-shim does not preserve Content-Type for WebUI JSON/AJAX POST requests"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Accept[[:space:]]+\$http_accept;' \
  || die "Checkmk auth-shim does not preserve Accept for dashboard/WebUI AJAX requests"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Cookie[[:space:]]+\$http_cookie;' \
  || die "Checkmk auth shim does not preserve Checkmk session cookies for CSRF-protected WebUI forms"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Authorization[[:space:]]+"";' \
  || die "Checkmk auth shim does not clear browser Authorization headers"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Forwarded-Proto[[:space:]]+https;' \
  || die "Checkmk auth shim does not force HTTPS scheme for the upstream Checkmk GUI"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-Original-User[[:space:]]+\$http_x_authentik_username;' \
  || die "Checkmk auth shim does not preserve original Authentik username"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-Email[[:space:]]+\$http_x_authentik_email;' \
  || die "Checkmk auth shim does not map Authentik email header"
printf '%s\n' "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-Groups[[:space:]]+\$http_x_authentik_groups;' \
  || die "Checkmk auth shim does not map Authentik groups header"

printf '%s\n' "$shim_conf" | grep -Eq 'location[[:space:]]*=[[:space:]]*/cmk/check_mk/logout\.py' \
  || die "Checkmk auth shim does not intercept the native Checkmk logout endpoint"
printf '%s\n' "$shim_conf" | grep -Eq 'https://auth\.' \
  || die "Checkmk auth shim must target the Authentik public host, not the Checkmk host"
printf '%s\n' "$shim_conf" | grep -Eq '/if/flow/default-invalidation-flow/' \
  || die "Checkmk logout is not redirected to the Authentik global logout flow"
printf '%s\n' "$shim_conf" | grep -Eq 'add_header[[:space:]]+Cache-Control[[:space:]]+"no-store"[[:space:]]+always;' \
  || die "Checkmk logout redirect does not disable browser caching"
printf '%s\n' "$shim_conf" | grep -Eq 'Set-Cookie.*auth_cmk=deleted' \
  || die "Checkmk logout redirect does not expire the stale Checkmk browser cookie"

checkmk_pod="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$checkmk_pod" ]] || die "Could not resolve Checkmk pod"
runtime_shim_conf="$(kubectl -n "$NAMESPACE" exec "$checkmk_pod" -c auth-shim -- sh -lc 'nginx -T 2>/dev/null' || true)"
printf '%s\n' "$runtime_shim_conf" | grep -Eq 'location[[:space:]]*=[[:space:]]*/cmk/check_mk/logout\.py' \
  || die "Running auth-shim nginx config does not contain the logout route; the pod is stale. Run 05.2 and wait for deployment/checkmk rollout."
printf '%s\n' "$runtime_shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Content-Type[[:space:]]+\$content_type;' \
  || die "Running auth-shim nginx config does not preserve Content-Type for WebUI JSON/AJAX POST requests; the pod is stale. Run 05.2 and wait for deployment/checkmk rollout."
printf '%s\n' "$runtime_shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Cookie[[:space:]]+\$http_cookie;' \
  || die "Running auth-shim nginx config does not preserve Checkmk session cookies; the pod is stale. Run 05.2 and wait for deployment/checkmk rollout."
printf '%s\n' "$runtime_shim_conf" | grep -Eq 'https://auth\.' \
  || die "Running auth-shim nginx config must target the Authentik public host, not the Checkmk host; the pod is stale. Run 05.2 and wait for deployment/checkmk rollout."
printf '%s\n' "$runtime_shim_conf" | grep -Eq '/if/flow/default-invalidation-flow/' \
  || die "Running auth-shim nginx config does not target Authentik global logout flow; the pod is stale. Run 05.2 and wait for deployment/checkmk rollout."

logout_headers="$(kubectl -n "$NAMESPACE" exec "$checkmk_pod" -c auth-shim -- env BASE_DOMAIN="$BASE_DOMAIN" sh -lc '
  curl -ksSI \
    -H "Host: checkmk.${BASE_DOMAIN}" \
    -H "X-authentik-username: cmkadmin" \
    http://127.0.0.1:8080/cmk/check_mk/logout.py
' || true)"
logout_code="$(printf '%s\n' "$logout_headers" | awk '/^HTTP\//{code=$2} END{print code}')"
[[ "$logout_code" =~ ^(301|302|303|307|308)$ ]] || die "Checkmk auth-shim logout path did not redirect to Authentik global logout flow, HTTP=${logout_code:-empty}"
logout_location="$(printf '%s\n' "$logout_headers" | awk 'BEGIN{IGNORECASE=1} /^Location:/{gsub("\r", "", $0); sub(/^[Ll]ocation:[[:space:]]*/, "", $0); print; exit}')"
case "$logout_location" in
  https://auth.*"/if/flow/default-invalidation-flow/"*) ;;
  *) die "Checkmk auth-shim logout redirect points to unexpected Location=${logout_location:-empty}" ;;
esac

checkmk_auth_conf="$(kubectl -n "$NAMESPACE" exec "$checkmk_pod" -c checkmk -- bash -lc "grep -n 'auth_by_http_header' /omd/sites/cmk/etc/check_mk/multisite.d/wato/global.mk 2>/dev/null || true")"
echo "$checkmk_auth_conf" | grep -q "X-Remote-User" || die "Checkmk site is not configured for X-Remote-User trusted-header authentication"

echo "PASS: Checkmk trusted-header SSO Kubernetes contract exists"
echo "PASS: Checkmk native logout redirects to Authentik global logout flow"
