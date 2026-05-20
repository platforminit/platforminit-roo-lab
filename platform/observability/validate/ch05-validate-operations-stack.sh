#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
warn(){ echo "WARN: $*" >&2; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
APP_NAME="${APP_NAME:-operations-stack}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
VALIDATION_MODE="${VALIDATION_MODE:-runtime}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
CHECKMK_LOCAL_PORT="${CHECKMK_LOCAL_PORT:-18085}"
export KUBECONFIG
[[ -n "${BASE_DOMAIN}" ]] || die "Missing BASE_DOMAIN. Set PLATFORM_BASE_DOMAIN; do not hardcode domains in CH05."
case "$VALIDATION_MODE" in runtime|runtime_with_sso) ;; *) die "Invalid VALIDATION_MODE=${VALIDATION_MODE}. Use runtime or runtime_with_sso." ;; esac
need kubectl
need curl
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null

diag(){
  log "Operations diagnostics"
  kubectl -n "$NAMESPACE" get pods,svc,ingressroute,pvc,certificate,middleware 2>/dev/null || true
  kubectl -n "$NAMESPACE" get events --sort-by=.lastTimestamp | tail -80 || true
  kubectl -n "$NAMESPACE" logs deploy/checkmk --all-containers --tail=160 || true
}
trap 'rc=$?; [[ $rc -eq 0 ]] || diag; exit $rc' EXIT

log "Validating Argo CD operations-stack health"
kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" >/dev/null || die "Missing Argo CD app ${APP_NAME}"
sync_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
health_status="$(kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME" -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
if [[ "$sync_status" != "Synced" ]]; then
  kubectl -n "$ARGOCD_NAMESPACE" get application.argoproj.io "$APP_NAME"     -o jsonpath='{range .status.resources[*]}{.kind}{"/"}{.name}{" sync="}{.status}{" health="}{.health.status}{"
"}{end}' 2>/dev/null || true
  die "operations-stack is not Synced: ${sync_status:-unknown}. Run 05.2 - Sync Operations Stack after CH05 manifest/config changes before validating."
fi
[[ "$health_status" == "Healthy" ]] || die "operations-stack is not Healthy: ${health_status:-unknown}"

log "Validating Checkmk runtime resources"
kubectl -n "$NAMESPACE" get secret checkmk-admin checkmk-sso >/dev/null
kubectl -n "$NAMESPACE" get pvc checkmk-sites >/dev/null
kubectl -n "$NAMESPACE" get svc checkmk >/dev/null
kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=240s >/dev/null
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "No Checkmk pod found"
kubectl -n "$NAMESPACE" exec "$POD" -c checkmk -- bash -lc "omd status ${CHECKMK_SITE}" >/tmp/ch05-checkmk-omd-status.txt || { cat /tmp/ch05-checkmk-omd-status.txt >&2 || true; die "Checkmk site status failed"; }

log "Validating Checkmk frontend through service port-forward"
kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 svc/checkmk "${CHECKMK_LOCAL_PORT}:5000" >/tmp/ch05-checkmk-port-forward.log 2>&1 &
PF="$!"
cleanup(){ kill "$PF" >/dev/null 2>&1 || true; }
trap 'rc=$?; cleanup; [[ $rc -eq 0 ]] || diag; exit $rc' EXIT
for _ in $(seq 1 45); do
  code="$(curl -sS -o /tmp/ch05-checkmk.html -w '%{http_code}' "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" || true)"
  [[ "$code" =~ ^(200|302|401|403)$ ]] && break
  sleep 2
done
code="$(curl -sS -o /tmp/ch05-checkmk.html -w '%{http_code}' "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" || true)"
[[ "$code" =~ ^(200|302|401|403)$ ]] || { cat /tmp/ch05-checkmk-port-forward.log >&2 || true; die "Checkmk frontend did not answer; HTTP=${code}"; }
log "PASS: Checkmk frontend answered HTTP ${code}"

log "Validating Checkmk managed service graph pages when CH05.5 model exists"
kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" <<'CHECKMK_GRAPH_VALIDATE'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

su - "${SITE}" -c "cmk -l" > "${TMP_DIR}/hosts.txt"
if ! grep -Fx "${PLATFORM_HOST}" "${TMP_DIR}/hosts.txt" >/dev/null; then
  echo "PASS: CH05.5 Checkmk host model not present yet; skipping managed service graph validation"
  exit 0
fi

for service in \
  "Host availability" \
  "SSH" \
  "Kubernetes API" \
  "Checkmk WebUI" \
  "Argo CD WebUI" \
  "Authentik WebUI" \
  "Root filesystem" \
  "Kubernetes runtime storage" \
  "Kubernetes PVC storage" \
  "Checkmk storage" \
  "Platform runtime artifacts"
do
  encoded_service="$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "${service}")"
  detail_file="${TMP_DIR}/service-${encoded_service}.html"
  code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o "${detail_file}" -w '%{http_code}' \
    "http://127.0.0.1:5000/${SITE}/check_mk/view.py?view_name=service&host=${PLATFORM_HOST}&service=${encoded_service}" || true)"
  case "${code}" in
    200|302|303) ;;
    *)
      echo "FATAL: Checkmk service detail page returned HTTP=${code} for service=${service}" >&2
      head -n 80 "${detail_file}" >&2 || true
      exit 1
      ;;
  esac
  if grep -Fq "graph_recipe" "${detail_file}"; then
    echo "FATAL: Checkmk service detail contains graph_recipe error for service=${service}" >&2
    exit 1
  fi
done

host_graphs_file="${TMP_DIR}/host-graphs.html"
host_graphs_code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o "${host_graphs_file}" -w '%{http_code}' \
  "http://127.0.0.1:5000/${SITE}/check_mk/view.py?view_name=host_graphs&host=${PLATFORM_HOST}&site=${SITE}" || true)"
case "${host_graphs_code}" in
  200|302|303) ;;
  *)
    echo "FATAL: Checkmk host graphs page returned HTTP=${host_graphs_code}" >&2
    head -n 80 "${host_graphs_file}" >&2 || true
    exit 1
    ;;
esac
if grep -Fq "graph_recipe" "${host_graphs_file}"; then
  echo "FATAL: Checkmk host graphs page contains graph_recipe error" >&2
  exit 1
fi

echo "PASS: Checkmk managed service detail pages have no graph_recipe errors"
echo "PASS: Checkmk host graphs page has no graph_recipe errors"
CHECKMK_GRAPH_VALIDATE

if [[ "$VALIDATION_MODE" == "runtime_with_sso" ]]; then
  log "Validating Checkmk Authentik trusted-header SSO Kubernetes contract"
  kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth >/dev/null || die "Missing Authentik forwardAuth middleware"
  kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-logout-redirect >/dev/null || die "Missing Authentik logout redirect middleware"
  kubectl -n "$NAMESPACE" get ingressroute.traefik.io checkmk >/dev/null || die "Missing Checkmk IngressRoute"
  kubectl -n "$NAMESPACE" get certificate checkmk-tls >/dev/null || die "Missing Checkmk TLS Certificate"
  checksum_annotation="$(kubectl -n "$NAMESPACE" get deployment checkmk -o go-template='{{ index .spec.template.metadata.annotations "checksum/auth-shim-config" }}' 2>/dev/null || true)"
  [[ -n "$checksum_annotation" ]] || die "Checkmk Deployment lacks checksum/auth-shim-config; auth-shim nginx can keep stale subPath-mounted ConfigMap content"

  addr="$(kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-forward-auth -o jsonpath='{.spec.forwardAuth.address}')"
  [[ "$addr" == *authentik-forward-auth.operations.svc.cluster.local*/outpost.goauthentik.io/auth/traefik* ]] || die "Unexpected forwardAuth endpoint: $addr"
  ingress_yaml="$(kubectl -n "$NAMESPACE" get ingressroute.traefik.io checkmk -o yaml)"
  printf '%s\n' "$ingress_yaml" | grep -q 'checkmk-authentik-forward-auth' || die "Checkmk IngressRoute is not protected by Authentik middleware"
  printf '%s\n' "$ingress_yaml" | grep -q 'checkmk-authentik-logout-redirect' || die "Checkmk IngressRoute does not route native Checkmk logout through Authentik global logout flow"
  printf '%s\n' "$ingress_yaml" | grep -q 'Path(`/cmk/check_mk/logout.py`)' || die "Checkmk IngressRoute does not have the native Checkmk logout path"
  printf '%s\n' "$ingress_yaml" | grep -q 'Path(`/cmk/logout.py`)' || die "Checkmk IngressRoute does not have the alternate Checkmk logout path"
  logout_redirect_yaml="$(kubectl -n "$NAMESPACE" get middleware.traefik.io checkmk-authentik-logout-redirect -o yaml)"
  printf '%s\n' "$logout_redirect_yaml" | grep -q 'https://auth\.' || die "Checkmk logout redirect middleware must target the Authentik public host, not the Checkmk host"
  printf '%s\n' "$logout_redirect_yaml" | grep -q '/if/flow/default-invalidation-flow/' || die "Checkmk logout redirect middleware does not target Authentik global logout flow"

  shim_conf="$(kubectl -n "$NAMESPACE" get configmap checkmk-nginx-auth-shim -o jsonpath='{.data.default\.conf}')"
  echo "$shim_conf" | grep -Eq 'proxy_pass_request_headers[[:space:]]+off;' || die "Checkmk auth-shim is still forwarding all browser/Authentik headers"
  echo "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Content-Type[[:space:]]+\$content_type;' || die "Checkmk auth-shim does not preserve Content-Type for WebUI JSON/AJAX POST requests"
  echo "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Accept[[:space:]]+\$http_accept;' || die "Checkmk auth-shim does not preserve Accept for dashboard/WebUI AJAX requests"
  echo "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Cookie[[:space:]]+\$http_cookie;' || die "Checkmk auth-shim does not preserve Checkmk session cookies for CSRF-protected WebUI forms"
  echo "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Forwarded-Proto[[:space:]]+https;' || die "Checkmk auth-shim does not preserve the public HTTPS scheme"
  echo "$shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+X-Remote-User[[:space:]]+cmkadmin;' || die "Checkmk auth-shim does not map approved sessions to cmkadmin"
  echo "$shim_conf" | grep -Eq 'location[[:space:]]*=[[:space:]]*/cmk/check_mk/logout\.py' || die "Checkmk auth-shim does not intercept native logout"
  echo "$shim_conf" | grep -Eq 'https://auth\.' || die "Checkmk auth-shim must target the Authentik public host, not the Checkmk host"
  echo "$shim_conf" | grep -Eq '/if/flow/default-invalidation-flow/' || die "Checkmk logout does not redirect to Authentik global logout flow"
  echo "$shim_conf" | grep -Eq 'add_header[[:space:]]+Cache-Control[[:space:]]+"no-store"[[:space:]]+always;' || die "Checkmk logout redirect does not disable browser caching"
  echo "$shim_conf" | grep -Eq 'Set-Cookie.*auth_cmk=deleted' || die "Checkmk logout redirect does not expire the stale Checkmk browser cookie"

  runtime_shim_conf="$(kubectl -n "$NAMESPACE" exec "$POD" -c auth-shim -- sh -lc 'nginx -T 2>/dev/null' || true)"
  echo "$runtime_shim_conf" | grep -Eq 'location[[:space:]]*=[[:space:]]*/cmk/check_mk/logout\.py' || die "Running auth-shim nginx config does not contain native logout interception; the pod is stale. Run 05.2 and wait for deployment/checkmk rollout."
  echo "$runtime_shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Content-Type[[:space:]]+\$content_type;' || die "Running auth-shim nginx config does not preserve Content-Type for WebUI JSON/AJAX POST requests; the pod is stale. Run 05.2 and wait for deployment/checkmk rollout."
  echo "$runtime_shim_conf" | grep -Eq 'proxy_set_header[[:space:]]+Cookie[[:space:]]+\$http_cookie;' || die "Running auth-shim nginx config does not preserve Checkmk session cookies; the pod is stale. Run 05.2 and wait for deployment/checkmk rollout."
  echo "$runtime_shim_conf" | grep -Eq 'https://auth\.' || die "Running auth-shim nginx config must target the Authentik public host, not the Checkmk host; the pod is stale. Run 05.2 and wait for deployment/checkmk rollout."
  echo "$runtime_shim_conf" | grep -Eq '/if/flow/default-invalidation-flow/' || die "Running auth-shim nginx config does not target Authentik global logout flow; the pod is stale. Run 05.2 and wait for deployment/checkmk rollout."

  log "Validating Checkmk auth-shim runtime path through service port 80"
  kill "$PF" >/dev/null 2>&1 || true
  kubectl -n "$NAMESPACE" port-forward --address 127.0.0.1 svc/checkmk "${CHECKMK_LOCAL_PORT}:80" >/tmp/ch05-checkmk-auth-shim-port-forward.log 2>&1 &
  PF="$!"
  for _ in $(seq 1 45); do
    shim_code="$(curl -sS       -H "Host: checkmk.${BASE_DOMAIN}"       -H "X-authentik-username: platforminit-test"       -H "X-authentik-email: platforminit-test@${BASE_DOMAIN}"       -H "Cookie: auth_cmk=stale-test-cookie"       -o /tmp/ch05-checkmk-auth-shim.html       -w '%{http_code}'       "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" || true)"
    [[ "$shim_code" =~ ^(200|302|401|403)$ ]] && break
    sleep 2
  done
  shim_code="$(curl -sS     -H "Host: checkmk.${BASE_DOMAIN}"     -H "X-authentik-username: platforminit-test"     -H "X-authentik-email: platforminit-test@${BASE_DOMAIN}"     -H "Cookie: auth_cmk=stale-test-cookie"     -o /tmp/ch05-checkmk-auth-shim.html     -w '%{http_code}'     "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/" || true)"
  if [[ ! "$shim_code" =~ ^(200|302|401|403)$ ]]; then
    cat /tmp/ch05-checkmk-auth-shim-port-forward.log >&2 || true
    kubectl -n "$NAMESPACE" logs "$POD" -c auth-shim --tail=160 >&2 || true
    kubectl -n "$NAMESPACE" exec "$POD" -c checkmk -- bash -lc 'tail -n 200 /omd/sites/cmk/var/log/web.log /omd/sites/cmk/var/log/apache/error_log 2>/dev/null || true' >&2 || true
    die "Checkmk auth-shim runtime path failed; HTTP=${shim_code}"
  fi
  logout_headers="$(curl -sSI \
    -H "Host: checkmk.${BASE_DOMAIN}" \
    -H "X-authentik-username: platforminit-test" \
    "http://127.0.0.1:${CHECKMK_LOCAL_PORT}/${CHECKMK_SITE}/check_mk/logout.py" || true)"
  logout_code="$(printf '%s\n' "$logout_headers" | awk '/^HTTP\//{code=$2} END{print code}')"
  [[ "$logout_code" =~ ^(301|302|303|307|308)$ ]] || die "Checkmk auth-shim logout path did not redirect to Authentik global logout flow, HTTP=${logout_code:-empty}"
  logout_location="$(printf '%s\n' "$logout_headers" | awk 'BEGIN{IGNORECASE=1} /^Location:/{gsub("\r", "", $0); sub(/^[Ll]ocation:[[:space:]]*/, "", $0); print; exit}')"
  case "$logout_location" in
    https://auth.*"/if/flow/default-invalidation-flow/"*) ;;
    *) die "Checkmk auth-shim logout redirect points to unexpected Location=${logout_location:-empty}" ;;
  esac

  log "PASS: Checkmk trusted-header SSO Kubernetes contract, auth-shim path and logout redirect are present"
fi

log "PASS: CH05 Checkmk operations stack validation succeeded mode=${VALIDATION_MODE}"
