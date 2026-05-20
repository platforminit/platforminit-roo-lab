#!/usr/bin/env bash
set -uo pipefail

log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
section(){ printf '\n===== %s =====\n' "$*"; }

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
SAMPLE_SERVICE_LIMIT="${SAMPLE_SERVICE_LIMIT:-25}"
BASE_DOMAIN="${BASE_DOMAIN:-example.invalid}"
DASHBOARD_SAMPLE_NAMES="${DASHBOARD_SAMPLE_NAMES:-main checkmk problems simple_problems}"
SESSION_PROBE_PATHS="${SESSION_PROBE_PATHS:-check_mk/dashboard.py?name=main&owner= check_mk/view.py?view_name=allhosts check_mk/wato.py?mode=global_settings}"
export KUBECONFIG

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
[[ -f "$KUBECONFIG" ]] || die "Missing kubeconfig at ${KUBECONFIG}"
command -v kubectl >/dev/null || die "kubectl is required"

section "diagnostic scope"
cat <<EOF
mode: data-collection-only
purpose: Checkmk graph/dashboard/session diagnostics
platform_host: ${PLATFORM_HOST}
namespace: ${NAMESPACE}
checkmk_site: ${CHECKMK_SITE}
sample_service_limit: ${SAMPLE_SERVICE_LIMIT}
dashboard_sample_names: ${DASHBOARD_SAMPLE_NAMES}
session_probe_paths: ${SESSION_PROBE_PATHS}
notes:
  - This workflow is intentionally read-only.
  - It does not change Checkmk configuration, service discovery, graph templates, RRD files or autochecks.
  - It collects graphing config, metric inventory, RRD/perfdata state, WebUI page probes and log excerpts.
  - It also compares direct Checkmk backend vs auth-shim behavior for dashboard AJAX, cookies, session continuity and CSRF token handling.
EOF

section "kubernetes operations status"
kubectl -n "$NAMESPACE" get deploy,pod,svc,endpoints,cm,secret -o wide 2>&1 || true
kubectl -n argocd get application operations-stack -o wide 2>&1 || true
kubectl -n "$NAMESPACE" get ingressroute.traefik.io,middleware.traefik.io -o wide 2>&1 || true

POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$POD" ]]; then
  die "No Checkmk pod found in namespace ${NAMESPACE}; cannot collect diagnostics"
fi

section "selected Checkmk pod"
echo "pod=${POD}"
kubectl -n "$NAMESPACE" describe pod "$POD" 2>&1 | sed -n '1,220p' || true

section "auth-shim runtime header/session contract"
kubectl -n "$NAMESPACE" exec "$POD" -c auth-shim -- sh -lc '
  nginx -T 2>/dev/null | grep -nE "proxy_pass_request_headers|proxy_set_header (Cookie|Content-Type|Authorization|X-Remote-User|X-Remote-Original-User|X-Forwarded)|Set-Cookie|logout.py|default-invalidation-flow" -A2 -B2 || true
' 2>&1 || true

section "Checkmk graph/dashboard/session diagnostics from site"
kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- \
  "$CHECKMK_SITE" "$PLATFORM_HOST" "$SAMPLE_SERVICE_LIMIT" "$BASE_DOMAIN" "$DASHBOARD_SAMPLE_NAMES" "$SESSION_PROBE_PATHS" <<'CHECKMK_GRAPH_DIAG'
set -uo pipefail
SITE="$1"
PLATFORM_HOST="$2"
SAMPLE_SERVICE_LIMIT="$3"
BASE_DOMAIN="$4"
DASHBOARD_SAMPLE_NAMES="$5"
SESSION_PROBE_PATHS="$6"
SITE_ROOT="/omd/sites/${SITE}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

section(){ printf '\n----- %s -----\n' "$*"; }
print_limited(){
  local file="$1"
  local lines="${2:-260}"
  if [[ -s "$file" ]]; then
    local count
    count="$(wc -l < "$file" | tr -d ' ')"
    sed -n "1,${lines}p" "$file"
    if [[ "${count}" -gt "${lines}" ]]; then
      echo "... output truncated: ${count} lines total; tail follows ..."
      tail -n 100 "$file"
    fi
  else
    echo "(empty)"
  fi
}
run_site(){
  local label="$1"
  local cmd="$2"
  section "$label"
  echo "+ su - ${SITE} -c ${cmd}"
  su - "${SITE}" -c "$cmd" >"${TMP_DIR}/${label}.out" 2>"${TMP_DIR}/${label}.err"
  local rc=$?
  echo "RC=${rc}"
  echo "--- stdout ---"
  print_limited "${TMP_DIR}/${label}.out"
  echo "--- stderr ---"
  print_limited "${TMP_DIR}/${label}.err"
  return 0
}
redact_headers(){
  sed -E 's/(Set-Cookie:[[:space:]]*[^=]+=)[^;]*/\1<redacted>/Ig; s/(Cookie:[[:space:]]*)[^\r]*/\1<redacted>/Ig; s/(Authorization:[[:space:]]*)[^\r]*/\1<redacted>/Ig'
}

if [[ ! -d "${SITE_ROOT}" ]]; then
  echo "FATAL: missing site root ${SITE_ROOT}"
  exit 0
fi

section "site/version/status"
id "${SITE}" || true
omd version 2>&1 || true
omd status "${SITE}" 2>&1 || true
ls -ld "${SITE_ROOT}" "${SITE_ROOT}/etc/check_mk" "${SITE_ROOT}/var/check_mk" "${SITE_ROOT}/tmp/check_mk" 2>&1 || true

run_site "cmk-version" "cmk -V && cmk --version"
run_site "cmk-host-configuration" "cmk -D '${PLATFORM_HOST}'"
run_site "cmk-core-config-host" "cmk -N '${PLATFORM_HOST}'"
run_site "cmk-cache-runtime-check" "cmk --cache -nv '${PLATFORM_HOST}'"
run_site "cmk-debug-cache-runtime-check" "cmk --debug --cache -vvn '${PLATFORM_HOST}'"

section "service inventory from generated core config"
su - "${SITE}" -c "cmk -N '${PLATFORM_HOST}'" >"${TMP_DIR}/core.cfg" 2>"${TMP_DIR}/core.err" || true
python3 - <<PY_CORE
from pathlib import Path
import re
text = Path('${TMP_DIR}/core.cfg').read_text(errors='replace')
services = re.findall(r'service_description\s+(.+)', text)
print(f'total_service_descriptions={len(services)}')
for idx, service in enumerate(services[:120], 1):
    print(f'{idx:03d} {service}')
PY_CORE

echo "--- native-looking service descriptions ---"
grep -Ei "service_description\s+(CPU|Memory|Filesystem|Interface|Uptime|Disk|Kernel|Systemd|Mount|TCP|Check_MK|Checkmk)" "${TMP_DIR}/core.cfg" | sed -n '1,180p' || true

echo "--- PlatformInit synthetic service descriptions ---"
grep -Ei "service_description\s+(Host availability|SSH|Kubernetes API|Checkmk WebUI|Argo CD WebUI|Authentik WebUI|Root filesystem|Kubernetes runtime storage|Kubernetes PVC storage|Checkmk storage|Platform runtime artifacts)" "${TMP_DIR}/core.cfg" | sed -n '1,180p' || true

section "Checkmk graphing and metric plugin files"
for dir in \
  "${SITE_ROOT}/local/share/check_mk/web/plugins/metrics" \
  "${SITE_ROOT}/share/check_mk/web/plugins/metrics" \
  "${SITE_ROOT}/local/lib/python3/cmk/gui/plugins/metrics" \
  "${SITE_ROOT}/lib/python3/cmk/gui/plugins/metrics" \
  "${SITE_ROOT}/local/lib/python3/cmk/gui/plugins/graphing" \
  "${SITE_ROOT}/lib/python3/cmk/gui/plugins/graphing" \
  "${SITE_ROOT}/local/lib/check_mk/base/plugins/agent_based" \
  "${SITE_ROOT}/lib/check_mk/base/plugins/agent_based"; do
  echo "--- ${dir} ---"
  if [[ -d "$dir" ]]; then
    find "$dir" -maxdepth 3 -type f | sort | sed -n '1,240p'
  else
    echo "(missing)"
  fi
done

echo "--- local platforminit graph/metric references ---"
find "${SITE_ROOT}/local" -type f 2>/dev/null | sort | while read -r file; do
  if grep -qEi "platforminit|graph_recipe|metric|perfdata|graph" "$file" 2>/dev/null; then
    echo "### ${file}"
    grep -nEi "platforminit|graph_recipe|metric|perfdata|graph" "$file" | sed -n '1,120p'
  fi
done

section "RRD, PNP and graph cache state for host"
for dir in \
  "${SITE_ROOT}/var/check_mk/rrd" \
  "${SITE_ROOT}/var/pnp4nagios/perfdata" \
  "${SITE_ROOT}/var/check_mk/graphing" \
  "${SITE_ROOT}/tmp/check_mk" \
  "${SITE_ROOT}/var/check_mk/web"; do
  echo "--- ${dir} ---"
  if [[ -d "$dir" ]]; then
    find "$dir" \( -path "*${PLATFORM_HOST}*" -o -name "*graph*" -o -name "*.rrd" \) 2>/dev/null | sort | sed -n '1,260p'
  else
    echo "(missing)"
  fi
done

section "Checkmk logs containing graph_recipe or graph failures"
if [[ -d "${SITE_ROOT}/var/log" ]]; then
  find "${SITE_ROOT}/var/log" -maxdepth 3 -type f | sort | while read -r log_file; do
    if grep -qEi "graph_recipe|Loading graph failed|exception|traceback|metric.*not|graph" "$log_file" 2>/dev/null; then
      echo "### ${log_file}"
      grep -nEi "graph_recipe|Loading graph failed|exception|traceback|metric.*not|graph" "$log_file" | tail -n 160
    fi
  done
else
  echo "missing ${SITE_ROOT}/var/log"
fi

section "WebUI service-page probes through trusted header"
python3 - <<PY_SERVICE >"${TMP_DIR}/probe_urls.sh"
from pathlib import Path
from urllib.parse import quote
import re
core = Path('${TMP_DIR}/core.cfg').read_text(errors='replace')
services = re.findall(r'service_description\s+(.+)', core)
try:
    limit = int('${SAMPLE_SERVICE_LIMIT}' or '25')
except ValueError:
    limit = 25
seen = []
for service in services:
    if service not in seen:
        seen.append(service)
for service in seen[:limit]:
    qs = 'check_mk/view.py?view_name=service&host=' + quote('${PLATFORM_HOST}', safe='') + '&service=' + quote(service, safe='')
    print('probe_service ' + quote(service) + ' ' + quote(qs, safe='/:?=&%'))
print('probe_hostgraphs ' + quote('host_graphs') + ' ' + quote('check_mk/view.py?view_name=host_graphs&host=' + '${PLATFORM_HOST}', safe='/:?=&%'))
PY_SERVICE
cat "${TMP_DIR}/probe_urls.sh"
while read -r kind encoded_name encoded_path; do
  [[ -n "${kind:-}" ]] || continue
  name="$(python3 - <<PY_NAME
from urllib.parse import unquote
print(unquote('${encoded_name}'))
PY_NAME
)"
  path="$(python3 - <<PY_PATH
from urllib.parse import unquote
print(unquote('${encoded_path}'))
PY_PATH
)"
  safe="$(echo "$kind-$name" | tr ' /:%?&=()' '__________' | tr -cd 'A-Za-z0-9_.-')"
  out="${TMP_DIR}/ui-${safe}.html"
  echo "--- ${kind}: ${name} -> /${SITE}/${path} ---"
  curl -ksS \
    -H 'X-Remote-User: cmkadmin' \
    -H 'X-Remote-Original-User: cmkadmin' \
    -H 'X-Remote-Email: cmkadmin@localhost' \
    -o "$out" \
    -w 'HTTP=%{http_code}\n' \
    "http://127.0.0.1:5000/${SITE}/${path}" 2>&1 || true
  echo "page_bytes=$(wc -c < "$out" 2>/dev/null || echo 0)"
  grep -nEi "graph_recipe|Loading graph failed|Traceback|Exception|ajax.*graph|render.*graph|metric|rrd" "$out" | sed -n '1,120p' || true
  grep -oE '[-A-Za-z0-9_/\.]*ajax[-A-Za-z0-9_/\.]*graph[-A-Za-z0-9_/?&=%.;:+]*' "$out" | sort -u | sed -n '1,80p' || true
done <"${TMP_DIR}/probe_urls.sh"

section "dashboard inventory and profile files"
for dir in \
  "${SITE_ROOT}/share/check_mk/web/htdocs" \
  "${SITE_ROOT}/lib/python3/cmk/gui" \
  "${SITE_ROOT}/local/share/check_mk/web" \
  "${SITE_ROOT}/var/check_mk/web" \
  "${SITE_ROOT}/etc/check_mk/multisite.d/wato"; do
  echo "--- ${dir} ---"
  if [[ -d "$dir" ]]; then
    find "$dir" -maxdepth 4 -type f \( -iname '*dashboard*' -o -iname '*sidebar*' -o -iname '*snapin*' -o -iname '*user*' -o -iname '*profile*' \) 2>/dev/null | sort | sed -n '1,220p'
  else
    echo "(missing)"
  fi
done

for file in \
  "${SITE_ROOT}/var/check_mk/web/cmkadmin/user_dashboards.mk" \
  "${SITE_ROOT}/var/check_mk/web/cmkadmin/user_settings.mk" \
  "${SITE_ROOT}/var/check_mk/web/cmkadmin/sidebar.mk" \
  "${SITE_ROOT}/etc/check_mk/multisite.d/wato/global.mk"; do
  echo "--- ${file} ---"
  if [[ -f "$file" ]]; then
    sed -n '1,220p' "$file"
  else
    echo "(missing)"
  fi
done

section "dashboard route probes: direct backend vs auth-shim"
python3 - <<PY_DASH >"${TMP_DIR}/dashboard_probe_urls.sh"
from urllib.parse import quote
names = '''${DASHBOARD_SAMPLE_NAMES}'''.split()
paths = ['check_mk/dashboard.py']
for name in names:
    base = 'check_mk/dashboard.py?name=' + quote(name, safe='') + '&owner='
    paths.append(base)
    paths.append('check_mk/index.py?start_url=' + quote('/cmk/' + base, safe=''))
for path in dict.fromkeys(paths):
    print(path)
PY_DASH
cat "${TMP_DIR}/dashboard_probe_urls.sh"
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  safe="$(echo "$path" | tr ' /:%?&=()' '__________' | tr -cd 'A-Za-z0-9_.-')"
  for mode in direct shim; do
    out="${TMP_DIR}/dashboard-${mode}-${safe}.html"
    hdr="${TMP_DIR}/dashboard-${mode}-${safe}.headers"
    if [[ "$mode" == direct ]]; then
      url="http://127.0.0.1:5000/${SITE}/${path}"
      header_args=(-H 'X-Remote-User: cmkadmin' -H 'X-Remote-Original-User: cmkadmin' -H 'X-Remote-Email: cmkadmin@localhost')
    else
      url="http://127.0.0.1:8080/${SITE}/${path}"
      header_args=(-H "Host: checkmk.${BASE_DOMAIN}" -H 'X-authentik-username: cmkadmin' -H 'X-authentik-name: cmkadmin' -H 'X-authentik-email: cmkadmin@localhost' -H 'X-authentik-groups: PlatformInit Admins')
    fi
    echo "--- dashboard ${mode}: /${SITE}/${path} ---"
    curl -ksS -D "$hdr" "${header_args[@]}" -o "$out" -w 'HTTP=%{http_code}\n' "$url" 2>&1 || true
    echo "headers:"; sed -n '1,80p' "$hdr" | redact_headers || true
    echo "page_bytes=$(wc -c < "$out" 2>/dev/null || echo 0)"
    echo "dashboard/html markers:"
    grep -nEi "Dashboard|Select dashboard|loading|spinner|ajax|fetch|XMLHttpRequest|csrf|graph_recipe|General error|Invalid CSRF|Traceback|Exception" "$out" | sed -n '1,160p' || true
    echo "candidate AJAX endpoints in HTML:"
    grep -oE '[-A-Za-z0-9_/\.]*ajax[-A-Za-z0-9_/\.]*[-A-Za-z0-9_/?&=%.;:+]*' "$out" | sort -u | sed -n '1,120p' || true
  done
done <"${TMP_DIR}/dashboard_probe_urls.sh"

section "session, cookie and CSRF continuity probes"
cat <<'SESSION_NOTE'
This section compares direct Checkmk backend requests with auth-shim requests.
If auth-shim strips Cookie, Checkmk may create a fresh session per request. That
can make forms fail with "Invalid CSRF token" even when GET pages render.
No POST/save action is executed by this diagnostic section.
SESSION_NOTE
python3 - <<PY_SESSION >"${TMP_DIR}/session_probe_urls.sh"
paths = '''${SESSION_PROBE_PATHS}'''.split()
if not paths:
    paths = ['check_mk/dashboard.py?name=main&owner=', 'check_mk/view.py?view_name=allhosts', 'check_mk/wato.py?mode=global_settings']
for path in dict.fromkeys(paths):
    print(path)
PY_SESSION
cat "${TMP_DIR}/session_probe_urls.sh"
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  safe="$(echo "$path" | tr ' /:%?&=()' '__________' | tr -cd 'A-Za-z0-9_.-')"
  for mode in direct shim; do
    jar="${TMP_DIR}/session-${mode}-${safe}.cookies"
    rm -f "$jar"
    out1="${TMP_DIR}/session-${mode}-${safe}-1.html"
    hdr1="${TMP_DIR}/session-${mode}-${safe}-1.headers"
    out2="${TMP_DIR}/session-${mode}-${safe}-2.html"
    hdr2="${TMP_DIR}/session-${mode}-${safe}-2.headers"
    if [[ "$mode" == direct ]]; then
      url="http://127.0.0.1:5000/${SITE}/${path}"
      header_args=(-H 'X-Remote-User: cmkadmin' -H 'X-Remote-Original-User: cmkadmin' -H 'X-Remote-Email: cmkadmin@localhost')
    else
      url="http://127.0.0.1:8080/${SITE}/${path}"
      header_args=(-H "Host: checkmk.${BASE_DOMAIN}" -H 'X-authentik-username: cmkadmin' -H 'X-authentik-name: cmkadmin' -H 'X-authentik-email: cmkadmin@localhost' -H 'X-authentik-groups: PlatformInit Admins')
    fi

    echo "--- session ${mode}: /${SITE}/${path} first GET ---"
    curl -ksS -D "$hdr1" -c "$jar" -b "$jar" "${header_args[@]}" -o "$out1" -w 'HTTP=%{http_code}\n' "$url" 2>&1 || true
    echo "first_response_set_cookie:"; grep -Ei '^Set-Cookie:' "$hdr1" | redact_headers | sed -n '1,40p' || true
    echo "cookie_jar_after_first:"; awk 'BEGIN{FS="\t"} /^#/ {next} NF>=7 {print $1, $3, $4, $5, $6, "<redacted>"}' "$jar" 2>/dev/null | sed -n '1,80p' || true
    echo "first_page_csrf/session markers:"; grep -nE "csrf|CSRF|_csrf|token|Token|session|auth_cmk|transid|_transid|secret" "$out1" | sed -E 's/(value=")[^"]*/\1<redacted>/g' | sed -n '1,120p' || true

    echo "--- session ${mode}: /${SITE}/${path} second GET with same curl cookie jar ---"
    curl -ksS -D "$hdr2" -c "$jar" -b "$jar" "${header_args[@]}" -o "$out2" -w 'HTTP=%{http_code}\n' "$url" 2>&1 || true
    echo "second_response_set_cookie:"; grep -Ei '^Set-Cookie:' "$hdr2" | redact_headers | sed -n '1,40p' || true
    echo "cookie_jar_after_second:"; awk 'BEGIN{FS="\t"} /^#/ {next} NF>=7 {print $1, $3, $4, $5, $6, "<redacted>"}' "$jar" 2>/dev/null | sed -n '1,80p' || true
    echo "second_page_csrf/session markers:"; grep -nE "csrf|CSRF|_csrf|token|Token|session|auth_cmk|transid|_transid|secret" "$out2" | sed -E 's/(value=")[^"]*/\1<redacted>/g' | sed -n '1,120p' || true
    echo "body_hash_first=$(sha256sum "$out1" 2>/dev/null | awk '{print $1}')"
    echo "body_hash_second=$(sha256sum "$out2" 2>/dev/null | awk '{print $1}')"
  done
done <"${TMP_DIR}/session_probe_urls.sh"

section "dashboard/session related Checkmk logs"
if [[ -d "${SITE_ROOT}/var/log" ]]; then
  find "${SITE_ROOT}/var/log" -maxdepth 3 -type f | sort | while read -r log_file; do
    if grep -qEi "dashboard|csrf|CSRF|Invalid CSRF|session|auth_cmk|cookie|ajax|traceback|exception" "$log_file" 2>/dev/null; then
      echo "### ${log_file}"
      grep -nEi "dashboard|csrf|CSRF|Invalid CSRF|session|auth_cmk|cookie|ajax|traceback|exception" "$log_file" | tail -n 220
    fi
  done
fi

section "post-probe Checkmk logs containing graph_recipe or graph failures"
if [[ -d "${SITE_ROOT}/var/log" ]]; then
  find "${SITE_ROOT}/var/log" -maxdepth 3 -type f | sort | while read -r log_file; do
    if grep -qEi "graph_recipe|Loading graph failed|exception|traceback|metric.*not|graph" "$log_file" 2>/dev/null; then
      echo "### ${log_file}"
      grep -nEi "graph_recipe|Loading graph failed|exception|traceback|metric.*not|graph" "$log_file" | tail -n 220
    fi
  done
fi
CHECKMK_GRAPH_DIAG

section "Checkmk pod logs after WebUI probes"
kubectl -n "$NAMESPACE" logs "$POD" -c checkmk --tail=220 2>&1 || true
kubectl -n "$NAMESPACE" logs "$POD" -c auth-shim --tail=160 2>&1 || true

log "CH05.8D graph/dashboard/session diagnostic collection completed. Review uploaded operations-graph-* artifact before making UI/auth-shim changes."
