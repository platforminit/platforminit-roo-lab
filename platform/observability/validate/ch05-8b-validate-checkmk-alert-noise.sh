#!/usr/bin/env bash
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
EXPECTED_MIN_SERVICES="${EXPECTED_MIN_SERVICES:-20}"
SYSTEMD_RESET_FAILED_UNITS="${SYSTEMD_RESET_FAILED_UNITS:-cloud-init-hotplugd.service dailyaidecheck.service}"
export KUBECONFIG

for unit in ${SYSTEMD_RESET_FAILED_UNITS}; do
  [[ -n "${unit}" ]] || continue
  if systemctl is-failed --quiet "${unit}"; then
    echo "FATAL: ${unit} is still failed after CH05.8B cleanup" >&2
    systemctl status "${unit}" --no-pager -l >&2 || true
    journalctl -u "${unit}" -n 80 --no-pager >&2 || true
    exit 1
  fi
done

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || { echo "FATAL: no Checkmk pod found" >&2; exit 1; }

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" "$EXPECTED_MIN_SERVICES" "$SYSTEMD_RESET_FAILED_UNITS" <<'CHECKMK_ALERT_VALIDATE'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
EXPECTED_MIN_SERVICES="$3"
SYSTEMD_RESET_FAILED_UNITS="$4"
SITE_ROOT="/omd/sites/${SITE}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

ALERT_REPORT="${SITE_ROOT}/local/share/platforminit/checkmk-alert-noise-cleanup.txt"
ALERT_SNAPSHOT="${SITE_ROOT}/local/share/platforminit/checkmk-alert-manager-current.txt"
DISCOVERY_REPORT="${SITE_ROOT}/local/share/platforminit/checkmk-discovery-reconcile.txt"
NOISE_RULE_FILE="${SITE_ROOT}/etc/check_mk/conf.d/platforminit/platforminit_noise_policy.mk"
DASHBOARD_CATALOG="${SITE_ROOT}/local/share/platforminit/checkmk-operations-dashboards.txt"

for file in "${ALERT_REPORT}" "${ALERT_SNAPSHOT}" "${DISCOVERY_REPORT}" "${NOISE_RULE_FILE}" "${DASHBOARD_CATALOG}"; do
  test -f "${file}" || { echo "FATAL: expected file missing: ${file}" >&2; exit 1; }
done

grep -F "Managed by PlatformInit CH05.8B" "${ALERT_REPORT}" >/dev/null
grep -F "Managed by PlatformInit CH05.8B" "${ALERT_SNAPSHOT}" >/dev/null
grep -F "Managed by PlatformInit CH05.8B" "${DISCOVERY_REPORT}" >/dev/null
grep -F "PlatformInit Alert Manager" "${DASHBOARD_CATALOG}" >/dev/null

grep -F 'Filesystem /run/k3s/containerd/.*/rootfs' "${NOISE_RULE_FILE}" >/dev/null
grep -F '"$regex"' "${NOISE_RULE_FILE}" >/dev/null

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
  grep -F "Filesystem /run/k3s/containerd/" "${TMP_DIR}/nagios.cfg" | head -n 80 >&2 || true
  exit 1
fi

if ! su - "${SITE}" -c "cmk --cache -nv '${PLATFORM_HOST}'" > "${TMP_DIR}/runtime-check.out" 2> "${TMP_DIR}/runtime-check.err"; then
  echo "WARN: cmk --cache -nv returned non-zero during validation; checking content" >&2
  head -n 120 "${TMP_DIR}/runtime-check.out" >&2 || true
  head -n 120 "${TMP_DIR}/runtime-check.err" >&2 || true
fi

if grep -E 'Check_MK Discovery.*(WARN|CRIT|UNKNOWN|unmonitored|vanished)' "${TMP_DIR}/runtime-check.out" >/dev/null; then
  echo "FATAL: Check_MK Discovery is still non-OK after CH05.8B cleanup" >&2
  grep -E 'Check_MK Discovery|unmonitored|vanished' "${TMP_DIR}/runtime-check.out" >&2 || true
  exit 1
fi

for unit in ${SYSTEMD_RESET_FAILED_UNITS}; do
  [[ -n "${unit}" ]] || continue
  unit_short="${unit%.service}"
  if grep -E "Systemd Service Summary|${unit}|${unit_short}" "${TMP_DIR}/runtime-check.out" | grep -E '(CRIT|WARN|UNKNOWN|failed)' >/dev/null; then
    echo "FATAL: systemd unit ${unit} still appears as a Checkmk problem" >&2
    grep -E "Systemd Service Summary|${unit}|${unit_short}" "${TMP_DIR}/runtime-check.out" >&2 || true
    exit 1
  fi
done

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

probe_url "alert-manager-dashboard" "dashboard.py?name=simple_problems&owner="
probe_url "main-dashboard" "dashboard.py?name=main&owner="
probe_url "host-status" "view.py?view_name=hoststatus&host=${PLATFORM_HOST}"
probe_url "service-problems" "view.py?view_name=svcproblems"

printf 'PASS: CH05.8B alert noise cleanup reports exist\n'
printf 'PASS: %s has %s generated services\n' "${PLATFORM_HOST}" "${service_count}"
printf 'PASS: Check_MK Discovery is clean after full discovery reconcile\n'
printf 'PASS: requested stale systemd failed units are no longer active Checkmk problems\n'
printf 'PASS: Alert Manager dashboard remains reachable without graph_recipe errors\n'
CHECKMK_ALERT_VALIDATE
