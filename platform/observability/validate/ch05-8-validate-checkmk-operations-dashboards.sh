#!/usr/bin/env bash
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
EXPECTED_MIN_SERVICES="${EXPECTED_MIN_SERVICES:-20}"
export KUBECONFIG

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || { echo "FATAL: no Checkmk pod found" >&2; exit 1; }

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" "$EXPECTED_MIN_SERVICES" <<'CHECKMK_DASHBOARD_VALIDATE'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
EXPECTED_MIN_SERVICES="$3"
SITE_ROOT="/omd/sites/${SITE}"
ALERT_MANAGER_DASHBOARD_URL="dashboard.py?name=simple_problems&owner="
START_URL="${ALERT_MANAGER_DASHBOARD_URL}"
MAIN_DASHBOARD_URL="dashboard.py?name=main&owner="
CHECKMK_DASHBOARD_URL="dashboard.py?name=checkmk&owner="
HOST_STATUS_URL="view.py?view_name=hoststatus&host=${PLATFORM_HOST}"
HOST_GRAPHS_URL="view.py?view_name=host_graphs&host=${PLATFORM_HOST}&site=${SITE}"
ALL_HOSTS_URL="view.py?view_name=allhosts"
ALL_SERVICES_URL="view.py?view_name=allservices"
SERVICE_PROBLEMS_URL="view.py?view_name=svcproblems"

UI_FILE="${SITE_ROOT}/etc/check_mk/multisite.d/wato/platforminit_operations_ui.mk"
USER_START_FILE="${SITE_ROOT}/var/check_mk/web/cmkadmin/start_url.mk"
DASHBOARD_CATALOG="${SITE_ROOT}/local/share/platforminit/checkmk-operations-dashboards.txt"
ALERT_SNAPSHOT="${SITE_ROOT}/local/share/platforminit/checkmk-alert-manager-current.txt"
NOISE_RULE_FILE="${SITE_ROOT}/etc/check_mk/conf.d/platforminit/platforminit_noise_policy.mk"

test -f "${UI_FILE}"
test -f "${USER_START_FILE}"
test -f "${DASHBOARD_CATALOG}"
test -f "${ALERT_SNAPSHOT}"
test -f "${NOISE_RULE_FILE}"
grep -F "start_url = '${START_URL}'" "${UI_FILE}" >/dev/null
grep -F "start_url = '${START_URL}'" "${USER_START_FILE}" >/dev/null
grep -F "PlatformInit Alert Manager" "${DASHBOARD_CATALOG}" >/dev/null
grep -F "dashboard.py?name=simple_problems&owner=" "${DASHBOARD_CATALOG}" >/dev/null
grep -F "dashboard.py?name=main&owner=" "${DASHBOARD_CATALOG}" >/dev/null
grep -F "view.py?view_name=host_graphs&host=${PLATFORM_HOST}&site=${SITE}" "${DASHBOARD_CATALOG}" >/dev/null
grep -F 'Filesystem /run/k3s/containerd/.*/rootfs' "${NOISE_RULE_FILE}" >/dev/null
grep -F '"$regex"' "${NOISE_RULE_FILE}" >/dev/null

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

su - "${SITE}" -c "cmk -D '${PLATFORM_HOST}'" > "${TMP_DIR}/host-model.txt"
grep -F '[agent:cmk-agent]' "${TMP_DIR}/host-model.txt" >/dev/null
grep -F '[tcp:tcp]' "${TMP_DIR}/host-model.txt" >/dev/null
grep -F 'TCP:' "${TMP_DIR}/host-model.txt" >/dev/null

su - "${SITE}" -c "cmk-validate-config" >/dev/null
su - "${SITE}" -c "cmk -N" > "${TMP_DIR}/nagios.cfg"
service_count="$(awk -v host="${PLATFORM_HOST}" '
  /^define service[[:space:]]*\{/ { in_block=1; block_host=""; block_service=""; next }
  in_block && $1 == "host_name" { block_host=$2; next }
  in_block && $1 == "service_description" { $1=""; sub(/^ +/, ""); block_service=$0; next }
  in_block && /^}/ {
    if (block_host == host && block_service != "") count++
    in_block=0
  }
  END { print count + 0 }
' "${TMP_DIR}/nagios.cfg")"
if [[ "${service_count}" -lt "${EXPECTED_MIN_SERVICES}" ]]; then
  echo "FATAL: expected at least ${EXPECTED_MIN_SERVICES} services for ${PLATFORM_HOST}, got ${service_count}" >&2
  exit 1
fi

if grep -F "Filesystem /run/k3s/containerd/" "${TMP_DIR}/nagios.cfg" | grep -F "/rootfs" >/dev/null; then
  echo "FATAL: transient k3s/containerd rootfs filesystem services are still generated" >&2
  grep -F "Filesystem /run/k3s/containerd/" "${TMP_DIR}/nagios.cfg" | head -n 40 >&2 || true
  exit 1
fi

probe_url() {
  local name="$1"
  local path="$2"
  local output="${TMP_DIR}/${name}.html"
  local code
  code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o "${output}" -w '%{http_code}' \
    "http://127.0.0.1:5000/${SITE}/check_mk/${path}" || true)"
  case "${code}" in
    200|302|303) ;;
    *)
      echo "FATAL: Checkmk dashboard/view probe failed: ${name} HTTP=${code} path=${path}" >&2
      head -n 100 "${output}" >&2 || true
      exit 1
      ;;
  esac
  if grep -Fq "graph_recipe" "${output}"; then
    echo "FATAL: Checkmk dashboard/view probe still contains graph_recipe error: ${name}" >&2
    exit 1
  fi
  echo "PASS: ${name} responds with HTTP=${code}"
}

probe_url "alert-manager-dashboard" "${ALERT_MANAGER_DASHBOARD_URL}"
probe_url "dashboard-main" "${MAIN_DASHBOARD_URL}"
probe_url "dashboard-checkmk" "${CHECKMK_DASHBOARD_URL}"
probe_url "host-status" "${HOST_STATUS_URL}"
probe_url "host-graphs" "${HOST_GRAPHS_URL}"
probe_url "all-hosts" "${ALL_HOSTS_URL}"
probe_url "all-services" "${ALL_SERVICES_URL}"
probe_url "service-problems" "${SERVICE_PROBLEMS_URL}"

echo "PASS: PlatformInit Alert Manager dashboard start URL is configured"
echo "PASS: PlatformInit Checkmk dashboard catalog exists"
echo "PASS: transient k3s/containerd overlay rootfs filesystem noise is ignored"
echo "PASS: ${PLATFORM_HOST} is a TCP Checkmk agent target with ${service_count} generated services"
echo "PASS: Checkmk Alert Manager, overview dashboards and drill-down routes respond without graph_recipe errors"
CHECKMK_DASHBOARD_VALIDATE
