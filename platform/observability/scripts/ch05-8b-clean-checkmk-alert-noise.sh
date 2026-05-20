#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
HOST_IPV4="${HOST_IPV4:-}"
EXPECTED_MIN_SERVICES="${EXPECTED_MIN_SERVICES:-20}"
SYSTEMD_RESET_FAILED_UNITS="${SYSTEMD_RESET_FAILED_UNITS:-cloud-init-hotplugd.service dailyaidecheck.service}"
CHECKMK_AGENT_PORT="${CHECKMK_AGENT_PORT:-6556}"
export KUBECONFIG

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
[[ -n "${HOST_IPV4}" ]] || die "HOST_IPV4 is required for deterministic Checkmk agent cache refresh"

REPORT_ROOT="/srv/platforminit/reports"
REPORT_FILE="${REPORT_ROOT}/ch05-8b-alert-noise-cleanup.txt"
mkdir -p "${REPORT_ROOT}"

log "Cleaning remaining Checkmk alert noise for host=${PLATFORM_HOST} host_ipv4=${HOST_IPV4} site=${CHECKMK_SITE}"

{
  echo "Managed by PlatformInit CH05.8B"
  echo "Generated at: $(date -u +%FT%TZ)"
  echo "Host: ${PLATFORM_HOST}"
  echo
  echo "=== systemctl --failed before cleanup ==="
  systemctl --failed --no-legend --plain || true
  echo
} > "${REPORT_FILE}"

# Clear stale failed systemd states for known non-runtime units. This does not
# disable or mask services; if a unit is actively failing, it will reappear and
# validation will fail with status/journal context.
for unit in ${SYSTEMD_RESET_FAILED_UNITS}; do
  [[ -n "${unit}" ]] || continue
  {
    echo
    echo "=== systemd unit before reset: ${unit} ==="
    systemctl status "${unit}" --no-pager -l || true
    echo
    echo "=== journal tail before reset: ${unit} ==="
    journalctl -u "${unit}" -n 80 --no-pager || true
  } >> "${REPORT_FILE}" 2>&1

  if systemctl is-failed --quiet "${unit}"; then
    log "Resetting stale failed state for ${unit}"
    systemctl reset-failed "${unit}" || true
  else
    log "Unit ${unit} is not currently in failed state; leaving untouched"
  fi

  {
    echo
    echo "=== systemd unit after reset: ${unit} ==="
    systemctl status "${unit}" --no-pager -l || true
  } >> "${REPORT_FILE}" 2>&1

done

{
  echo
  echo "=== systemctl --failed after cleanup ==="
  systemctl --failed --no-legend --plain || true
} >> "${REPORT_FILE}"

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null || die "Checkmk deployment is not ready"
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "No Checkmk pod found"

log "Reconciling Checkmk discovery and Alert Manager current-problem snapshot in pod/${POD}"

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- \
  "$CHECKMK_SITE" "$PLATFORM_HOST" "$HOST_IPV4" "$CHECKMK_AGENT_PORT" "$EXPECTED_MIN_SERVICES" "$SYSTEMD_RESET_FAILED_UNITS" <<'CHECKMK_ALERT_CLEANUP'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
HOST_IPV4="$3"
PORT="$4"
EXPECTED_MIN_SERVICES="$5"
SYSTEMD_RESET_FAILED_UNITS="$6"
SITE_ROOT="/omd/sites/${SITE}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

REPORT_DIR="${SITE_ROOT}/local/share/platforminit"
mkdir -p "${REPORT_DIR}" "${SITE_ROOT}/tmp/check_mk/cache"
ALERT_REPORT="${REPORT_DIR}/checkmk-alert-noise-cleanup.txt"
ALERT_SNAPSHOT="${REPORT_DIR}/checkmk-alert-manager-current.txt"
DISCOVERY_REPORT="${REPORT_DIR}/checkmk-discovery-reconcile.txt"

run_site_cmd() {
  local label="$1"
  shift
  local cmd="$*"
  if ! su - "${SITE}" -c "${cmd}" > "${TMP_DIR}/${label}.out" 2> "${TMP_DIR}/${label}.err"; then
    echo "FATAL: Checkmk command failed: ${cmd}" >&2
    echo "--- ${label} stdout ---" >&2
    head -n 220 "${TMP_DIR}/${label}.out" >&2 || true
    echo "--- ${label} stderr ---" >&2
    head -n 220 "${TMP_DIR}/${label}.err" >&2 || true
    echo "--- cmk -D ${PLATFORM_HOST} ---" >&2
    su - "${SITE}" -c "cmk -D '${PLATFORM_HOST}'" >&2 || true
    echo "--- autochecks ---" >&2
    find "${SITE_ROOT}/var/check_mk/autochecks" -maxdepth 2 -type f -name "${PLATFORM_HOST}.mk" -print -exec sed -n '1,240p' {} \; >&2 || true
    exit 1
  fi
}

run_site_cmd_warn() {
  local label="$1"
  shift
  local cmd="$*"
  if ! su - "${SITE}" -c "${cmd}" > "${TMP_DIR}/${label}.out" 2> "${TMP_DIR}/${label}.err"; then
    echo "WARN: non-fatal Checkmk command failed: ${cmd}" >&2
    echo "--- ${label} stdout ---" >&2
    head -n 180 "${TMP_DIR}/${label}.out" >&2 || true
    echo "--- ${label} stderr ---" >&2
    head -n 180 "${TMP_DIR}/${label}.err" >&2 || true
    return 1
  fi
}

write_agent_cache() {
  local cache_file="${SITE_ROOT}/tmp/check_mk/cache/${PLATFORM_HOST}"
  if ! timeout 25 bash -lc "exec 3<>/dev/tcp/${HOST_IPV4}/${PORT}; cat <&3" > "${TMP_DIR}/agent-cache.raw"; then
    echo "FATAL: cannot refresh Checkmk agent cache from ${HOST_IPV4}:${PORT}" >&2
    exit 1
  fi
  grep -F '<<<check_mk>>>' "${TMP_DIR}/agent-cache.raw" >/dev/null || {
    echo "FATAL: agent cache refresh did not contain <<<check_mk>>>" >&2
    head -n 120 "${TMP_DIR}/agent-cache.raw" >&2 || true
    exit 1
  }
  install -m 0644 "${TMP_DIR}/agent-cache.raw" "${cache_file}"
  chown "${SITE}:${SITE}" "${cache_file}"
}

run_site_cmd config-validation-before-cleanup "cmk-validate-config"
run_site_cmd cmk-host-list "cmk -l"
grep -Fx "${PLATFORM_HOST}" "${TMP_DIR}/cmk-host-list.out" >/dev/null || {
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not defined; run CH05.5 first" >&2
  cat "${TMP_DIR}/cmk-host-list.out" >&2
  exit 1
}

su - "${SITE}" -c "cmk -D '${PLATFORM_HOST}'" > "${TMP_DIR}/host-model.txt" 2>&1 || true
if ! grep -Eq 'Type of agent:[[:space:]]*TCP|Normal Checkmk agent|TCP:' "${TMP_DIR}/host-model.txt"; then
  echo "FATAL: ${PLATFORM_HOST} is not a TCP Checkmk agent target; run CH05.7 first" >&2
  cat "${TMP_DIR}/host-model.txt" >&2
  exit 1
fi

write_agent_cache
run_site_cmd cmk-agent-fetch "cmk -d '${PLATFORM_HOST}'"
section_hits="$(grep -Ec '^<<<(df_v2|mem|cpu|uptime|lnx_if|systemd_units|diskstat|kernel)' "${TMP_DIR}/cmk-agent-fetch.out" || true)"
if [[ "${section_hits}" -lt 4 ]]; then
  echo "FATAL: Checkmk fetched the agent but did not expose enough native Linux sections, got ${section_hits}" >&2
  head -n 180 "${TMP_DIR}/cmk-agent-fetch.out" >&2 || true
  exit 1
fi

# Full discovery reconcile clears vanished/unmonitored drift behind the Check_MK
# Discovery service. The transient filesystem ignore policy from CH05.8 remains
# in force and prevents k3s/containerd overlay rootfs services from returning.
run_site_cmd discovery-full-reconcile "cmk --cache -vII '${PLATFORM_HOST}'"
if ! run_site_cmd_warn reload-after-discovery-reconcile "cmk -R"; then
  echo "WARN: cmk -R failed after discovery reconcile; trying cmk -O" >&2
  run_site_cmd reload-after-discovery-reconcile-fallback "cmk -O"
fi

write_agent_cache
run_site_cmd_warn runtime-check-after-cleanup "cmk --cache -nv '${PLATFORM_HOST}'" || true
run_site_cmd core-config-after-cleanup "cmk -N"
cp "${TMP_DIR}/core-config-after-cleanup.out" "${TMP_DIR}/nagios.cfg"

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
  grep -A5 -B2 -E "host_name[[:space:]]+${PLATFORM_HOST}|service_description" "${TMP_DIR}/nagios.cfg" | head -n 220 >&2 || true
  exit 1
fi

if grep -F "Filesystem /run/k3s/containerd/" "${TMP_DIR}/nagios.cfg" | grep -F "/rootfs" >/dev/null; then
  echo "FATAL: transient k3s/containerd rootfs filesystem services returned after cleanup" >&2
  grep -F "Filesystem /run/k3s/containerd/" "${TMP_DIR}/nagios.cfg" | head -n 80 >&2 || true
  exit 1
fi

# If Check_MK Discovery is still non-OK after a full reconcile, continuing would
# keep the Alert Manager dashboard noisy and hide real problems.
if grep -E 'Check_MK Discovery.*(WARN|CRIT|UNKNOWN|unmonitored|vanished)' "${TMP_DIR}/runtime-check-after-cleanup.out" >/dev/null; then
  echo "FATAL: Check_MK Discovery remains non-OK after full discovery reconcile" >&2
  grep -E 'Check_MK Discovery|unmonitored|vanished' "${TMP_DIR}/runtime-check-after-cleanup.out" >&2 || true
  echo "--- discovery reconcile stdout ---" >&2
  head -n 220 "${TMP_DIR}/discovery-full-reconcile.out" >&2 || true
  echo "--- autochecks ---" >&2
  find "${SITE_ROOT}/var/check_mk/autochecks" -maxdepth 2 -type f -name "${PLATFORM_HOST}.mk" -print -exec sed -n '1,260p' {} \; >&2 || true
  exit 1
fi

# Stale failed systemd states were reset on the host before cache refresh. If
# they still appear in the Checkmk runtime output, the issue is active and must
# be fixed in CH02/host baseline instead of hidden in the dashboard layer.
for unit in ${SYSTEMD_RESET_FAILED_UNITS}; do
  [[ -n "${unit}" ]] || continue
  unit_short="${unit%.service}"
  if grep -E "Systemd Service Summary|${unit}|${unit_short}" "${TMP_DIR}/runtime-check-after-cleanup.out" | grep -E '(CRIT|WARN|UNKNOWN|failed)' >/dev/null; then
    echo "FATAL: systemd unit ${unit} still appears as a Checkmk problem after reset-failed" >&2
    grep -E "Systemd Service Summary|${unit}|${unit_short}" "${TMP_DIR}/runtime-check-after-cleanup.out" >&2 || true
    exit 1
  fi
done

{
  echo "Managed by PlatformInit CH05.8B"
  echo "Generated at: $(date -u +%FT%TZ)"
  echo "Host: ${PLATFORM_HOST}"
  echo "Agent: ${HOST_IPV4}:${PORT}"
  echo "Generated services: ${service_count}"
  echo "Native agent sections: ${section_hits}"
  echo
  echo "Reset-failed units requested: ${SYSTEMD_RESET_FAILED_UNITS}"
  echo
  echo "=== Discovery reconcile stdout ==="
  cat "${TMP_DIR}/discovery-full-reconcile.out"
  echo
  echo "=== Discovery reconcile stderr ==="
  cat "${TMP_DIR}/discovery-full-reconcile.err"
  echo
  echo "=== Runtime non-OK snapshot ==="
  grep -E '(^|[[:space:]])(WARN|CRIT|UNKNOWN|DOWN|UNREACH)' "${TMP_DIR}/runtime-check-after-cleanup.out" || true
} > "${ALERT_REPORT}"

{
  echo "Managed by PlatformInit CH05.8B"
  echo "Generated at: $(date -u +%FT%TZ)"
  echo "Host: ${PLATFORM_HOST}"
  echo
  echo "Current Alert Manager non-OK lines after cleanup:"
  grep -E '(^|[[:space:]])(WARN|CRIT|UNKNOWN|DOWN|UNREACH)' "${TMP_DIR}/runtime-check-after-cleanup.out" || true
} > "${ALERT_SNAPSHOT}"

{
  echo "Managed by PlatformInit CH05.8B"
  echo "Generated at: $(date -u +%FT%TZ)"
  echo "Host: ${PLATFORM_HOST}"
  echo "service_count=${service_count}"
  echo
  echo "Discovery reconcile output:"
  cat "${TMP_DIR}/discovery-full-reconcile.out"
} > "${DISCOVERY_REPORT}"

chown "${SITE}:${SITE}" "${ALERT_REPORT}" "${ALERT_SNAPSHOT}" "${DISCOVERY_REPORT}"

echo "PASS: refreshed Checkmk agent cache from ${HOST_IPV4}:${PORT}"
echo "PASS: full discovery reconcile completed without Check_MK Discovery WARN/CRIT"
echo "PASS: transient k3s/containerd overlay rootfs services remain ignored"
echo "PASS: requested stale systemd failed units no longer appear as active Checkmk problems"
echo "PASS: Alert Manager snapshot updated at ${ALERT_SNAPSHOT}"
CHECKMK_ALERT_CLEANUP

log "CH05.8B Checkmk alert-noise cleanup completed"
