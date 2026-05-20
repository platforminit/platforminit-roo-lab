#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
export KUBECONFIG
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
