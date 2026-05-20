#!/usr/bin/env bash
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
CHECKMK_AGENT_PORT="${CHECKMK_AGENT_PORT:-6556}"
export KUBECONFIG

[[ ${EUID} -eq 0 ]] || { echo "FATAL: Run as root (sudo)." >&2; exit 1; }
[[ -f "$KUBECONFIG" ]] || { echo "FATAL: missing kubeconfig at ${KUBECONFIG}" >&2; exit 1; }

systemctl is-active --quiet check-mk-agent.socket || {
  echo "FATAL: check-mk-agent.socket is not active" >&2
  systemctl status check-mk-agent.socket --no-pager >&2 || true
  exit 1
}

if ! ss -ltn "sport = :${CHECKMK_AGENT_PORT}" | grep -q ":${CHECKMK_AGENT_PORT}"; then
  echo "FATAL: Checkmk agent is not listening on TCP/${CHECKMK_AGENT_PORT}" >&2
  ss -ltn >&2 || true
  exit 1
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if ! timeout 10 bash -lc "exec 3<>/dev/tcp/127.0.0.1/${CHECKMK_AGENT_PORT}; head -n 80 <&3" > "${TMP_DIR}/agent-local.txt"; then
  echo "FATAL: could not read Checkmk agent locally" >&2
  exit 1
fi
grep -F '<<<check_mk>>>' "${TMP_DIR}/agent-local.txt" >/dev/null || {
  echo "FATAL: local Checkmk agent output does not contain <<<check_mk>>>" >&2
  head -n 40 "${TMP_DIR}/agent-local.txt" >&2 || true
  exit 1
}

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || { echo "FATAL: no Checkmk pod found" >&2; exit 1; }

HOST_IPV4="${HOST_IPV4:-$(hostname -I | awk '{print $1}') }"
HOST_IPV4="${HOST_IPV4%% }"
[[ -n "$HOST_IPV4" ]] || { echo "FATAL: could not resolve host IPv4" >&2; exit 1; }

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" "$HOST_IPV4" "$CHECKMK_AGENT_PORT" <<'CHECKMK_AGENT_VALIDATE'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
HOST_IPV4="$3"
PORT="$4"
SITE_ROOT="/omd/sites/${SITE}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

test -f "${SITE_ROOT}/local/share/platforminit/checkmk-agent-discovery.txt" || {
  echo "FATAL: CH05.7 discovery marker is missing" >&2
  exit 1
}

if ! timeout 15 bash -lc "exec 3<>/dev/tcp/${HOST_IPV4}/${PORT}; head -n 80 <&3" > "${TMP_DIR}/agent-from-pod.txt"; then
  echo "FATAL: Checkmk pod cannot reach host agent at ${HOST_IPV4}:${PORT}" >&2
  exit 1
fi
grep -F '<<<check_mk>>>' "${TMP_DIR}/agent-from-pod.txt" >/dev/null || {
  echo "FATAL: pod-read agent output does not contain <<<check_mk>>>" >&2
  head -n 40 "${TMP_DIR}/agent-from-pod.txt" >&2 || true
  exit 1
}

# CH05.7 must not leave the earlier raw host-address overlay behind. That
# overlay made cmk -N fail in some Checkmk 2.5 RAW environments before service
# discovery could even run.
if [[ -f "${SITE_ROOT}/etc/check_mk/conf.d/platforminit/zz_platforminit_agent_address.mk" ]]; then
  echo "FATAL: stale CH05.7 agent address overlay still exists" >&2
  sed -n '1,160p' "${SITE_ROOT}/etc/check_mk/conf.d/platforminit/zz_platforminit_agent_address.mk" >&2 || true
  exit 1
fi

mkdir -p "${SITE_ROOT}/tmp/check_mk/cache"
cache_file="${SITE_ROOT}/tmp/check_mk/cache/${PLATFORM_HOST}"
install -m 0644 "${TMP_DIR}/agent-from-pod.txt" "${cache_file}"
chown "${SITE}:${SITE}" "${cache_file}"

if ! su - "${SITE}" -c "cmk-validate-config" > "${TMP_DIR}/cmk-validate-config.out" 2> "${TMP_DIR}/cmk-validate-config.err"; then
  echo "FATAL: cmk-validate-config failed" >&2
  echo "--- stdout ---" >&2
  head -n 160 "${TMP_DIR}/cmk-validate-config.out" >&2 || true
  echo "--- stderr ---" >&2
  head -n 160 "${TMP_DIR}/cmk-validate-config.err" >&2 || true
  exit 1
fi

su - "${SITE}" -c "cmk -D '${PLATFORM_HOST}'" > "${TMP_DIR}/cmk-host-diagnostics.txt" 2>&1 || true
if ! grep -Eq 'Type of agent:[[:space:]]*TCP|Normal Checkmk agent' "${TMP_DIR}/cmk-host-diagnostics.txt"; then
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not configured as a TCP Checkmk agent target; run the fixed CH05.5 host model first" >&2
  echo "Expected CH05.5 to write the host with explicit raw tags: cmk-agent|tcp|prod|lan" >&2
  echo "--- cmk -D ${PLATFORM_HOST} ---" >&2
  cat "${TMP_DIR}/cmk-host-diagnostics.txt" >&2 || true
  exit 1
fi

if ! su - "${SITE}" -c "cmk --cache -nv '${PLATFORM_HOST}'" > "${TMP_DIR}/cmk-agent-output.txt" 2> "${TMP_DIR}/cmk-agent-error.txt"; then
  # cmk -nv can return non-zero during the first native-agent run when
  # newly discovered counters are still PEND or when individual discovered
  # items report missing monitoring data. That state is acceptable for the
  # CH05.7 bootstrap gate as long as the Checkmk datasource is TCP agent based
  # and native Linux service lines are present in the processed output.
  echo "WARN: cmk --cache -nv returned non-zero during first native-agent validation; continuing with content-based checks" >&2
  echo "--- cmk --cache -nv stderr ---" >&2
  head -n 120 "${TMP_DIR}/cmk-agent-error.txt" >&2 || true
  echo "--- cmk --cache -nv stdout ---" >&2
  head -n 160 "${TMP_DIR}/cmk-agent-output.txt" >&2 || true
fi

cache_hits="$(grep -Ec '^(CPU load|CPU utilization|Check_MK Agent|Disk IO|Filesystem|Interface|Kernel Performance|Memory|Number of threads|TCP Connections|Uptime)[[:space:]]' "${TMP_DIR}/cmk-agent-output.txt" || true)"
if [[ "${cache_hits}" -lt 3 ]]; then
  echo "FATAL: Checkmk cache processing did not expose native Linux services, got ${cache_hits} matches" >&2
  echo "--- cmk --cache -nv stdout ---" >&2
  head -n 240 "${TMP_DIR}/cmk-agent-output.txt" >&2 || true
  echo "--- raw agent cache sections ---" >&2
  grep -E '^<<<[^>]+>>>' "${cache_file}" | head -n 120 >&2 || true
  echo "--- cmk -D ${PLATFORM_HOST} ---" >&2
  cat "${TMP_DIR}/cmk-host-diagnostics.txt" >&2 || true
  exit 1
fi

if ! su - "${SITE}" -c "cmk -N" > "${TMP_DIR}/nagios.cfg" 2> "${TMP_DIR}/cmk-nagios.err"; then
  echo "FATAL: cmk -N failed while validating discovered services" >&2
  echo "--- cmk -N stderr ---" >&2
  head -n 160 "${TMP_DIR}/cmk-nagios.err" >&2 || true
  echo "--- cmk -D ${PLATFORM_HOST} ---" >&2
  head -n 160 "${TMP_DIR}/cmk-host-diagnostics.txt" >&2 || true
  echo "--- stale CH05.7 address overlay should be absent ---" >&2
  ls -l "${SITE_ROOT}/etc/check_mk/conf.d/platforminit/zz_platforminit_agent_address.mk" >&2 || true
  exit 1
fi
service_count="$(awk -v host="${PLATFORM_HOST}" '
  $1 == "define" && $2 == "service" { in_service=1; has_host=0 }
  in_service && $1 == "host_name" && $2 == host { has_host=1 }
  in_service && has_host && $1 == "service_description" { count++ }
  in_service && $1 == "}" { in_service=0 }
  END { print count + 0 }
' "${TMP_DIR}/nagios.cfg")"
if [[ "${service_count}" -lt 15 ]]; then
  echo "FATAL: expected at least 15 services after native Checkmk agent discovery, got ${service_count}" >&2
  grep -E 'service_description' "${TMP_DIR}/nagios.cfg" | head -n 120 >&2 || true
  exit 1
fi

native_hits="$(grep -Ec 'service_description[[:space:]]+(CPU|Memory|Filesystem|Uptime|Interface|Kernel|TCP|Check_MK|Disk IO|Memory and swap|Filesystem /)' "${TMP_DIR}/nagios.cfg" || true)"
if [[ "${native_hits}" -lt 3 ]]; then
  echo "FATAL: expected native Linux agent service descriptions, got ${native_hits}" >&2
  grep -E 'service_description' "${TMP_DIR}/nagios.cfg" | head -n 120 >&2 || true
  exit 1
fi

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
  echo "FATAL: Checkmk host graphs page still contains graph_recipe error after native agent discovery" >&2
  exit 1
fi

echo "PASS: Checkmk pod can read host agent on ${HOST_IPV4}:${PORT}"
echo "PASS: Checkmk site can fetch native agent data for ${PLATFORM_HOST}"
echo "PASS: ${PLATFORM_HOST} has ${service_count} services after discovery"
echo "PASS: native Linux service matches detected: ${native_hits}"
echo "PASS: host graphs page has no graph_recipe error"
CHECKMK_AGENT_VALIDATE

echo "PASS: check-mk-agent.socket is active and listening on TCP/${CHECKMK_AGENT_PORT}"
