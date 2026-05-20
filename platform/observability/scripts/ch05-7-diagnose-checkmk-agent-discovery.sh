#!/usr/bin/env bash
set -uo pipefail

log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
section(){ printf '\n===== %s =====\n' "$*"; }

run_cmd(){
  local label="$1"; shift
  section "$label"
  echo "+ $*"
  "$@"
  local rc=$?
  echo "RC=${rc}"
  return 0
}

run_bash(){
  local label="$1"
  local cmd="$2"
  section "$label"
  echo "+ ${cmd}"
  bash -lc "$cmd"
  local rc=$?
  echo "RC=${rc}"
  return 0
}

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
CHECKMK_AGENT_PORT="${CHECKMK_AGENT_PORT:-6556}"
RUN_DISCOVERY_PROBE="${RUN_DISCOVERY_PROBE:-false}"
export KUBECONFIG

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
[[ -f "$KUBECONFIG" ]] || die "Missing kubeconfig at ${KUBECONFIG}"
command -v kubectl >/dev/null || die "kubectl is required"

HOST_IPV4="${HOST_IPV4:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
[[ -n "$HOST_IPV4" ]] || HOST_IPV4="unknown"

section "diagnostic scope"
cat <<EOF
mode: data-collection-only
platform_host: ${PLATFORM_HOST}
host_ipv4: ${HOST_IPV4}
namespace: ${NAMESPACE}
checkmk_site: ${CHECKMK_SITE}
agent_port: ${CHECKMK_AGENT_PORT}
run_discovery_probe: ${RUN_DISCOVERY_PROBE}
notes:
  - Default mode does not run cmk -I because it can write autochecks.
  - Set run_discovery_probe=true only when you intentionally want a state-changing discovery probe.
EOF

section "host operating system"
uname -a || true
cat /etc/os-release 2>/dev/null || true
dpkg --print-architecture 2>/dev/null || true
hostname -f 2>/dev/null || hostname || true
ip -brief address 2>/dev/null || true
ip route 2>/dev/null || true

run_bash "host checkmk agent binary and package state" '
set +e
command -v check_mk_agent || true
ls -l /usr/bin/check_mk_agent /usr/lib/check_mk_agent /etc/check_mk 2>/dev/null || true
dpkg -l | grep -Ei "check.?mk|check-mk-agent" || true
systemctl status check-mk-agent.socket --no-pager 2>&1 || true
systemctl cat check-mk-agent.socket check-mk-agent@.service 2>&1 || true
ss -ltnp 2>/dev/null | grep -E ":6556\\b|check" || ss -ltnp 2>/dev/null || true
ufw status verbose 2>/dev/null || true
'

run_bash "host local agent tcp probe" "
set +e
if timeout 10 bash -lc 'exec 3<>/dev/tcp/127.0.0.1/${CHECKMK_AGENT_PORT}; head -n 160 <&3' > /tmp/platforminit-local-agent-diag.txt 2>/tmp/platforminit-local-agent-diag.err; then
  echo 'local_tcp_probe=OK'
  grep -E '^<<<[^>]+>>>' /tmp/platforminit-local-agent-diag.txt | head -n 80 || true
  sed -n '1,80p' /tmp/platforminit-local-agent-diag.txt || true
else
  echo 'local_tcp_probe=FAILED'
  cat /tmp/platforminit-local-agent-diag.err || true
fi
"

section "kubernetes operations namespace overview"
kubectl -n "$NAMESPACE" get deploy,pod,svc,endpoints,cm,secret -o wide 2>&1 || true
kubectl -n argocd get application operations-stack -o wide 2>&1 || true
kubectl -n "$NAMESPACE" get ingressroute.traefik.io,middleware.traefik.io -o wide 2>&1 || true

POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$POD" ]]; then
  die "No Checkmk pod found in namespace ${NAMESPACE}; cannot collect Checkmk diagnostics"
fi

section "selected Checkmk pod"
echo "pod=${POD}"
kubectl -n "$NAMESPACE" describe pod "$POD" 2>&1 | sed -n '1,220p' || true

section "Checkmk pod logs tail"
kubectl -n "$NAMESPACE" logs "$POD" -c checkmk --tail=160 2>&1 || true
kubectl -n "$NAMESPACE" logs "$POD" -c auth-shim --tail=120 2>&1 || true

section "Checkmk site diagnostics from pod"
kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" "$HOST_IPV4" "$CHECKMK_AGENT_PORT" "$RUN_DISCOVERY_PROBE" <<'CHECKMK_DIAG'
set -uo pipefail
SITE="$1"
PLATFORM_HOST="$2"
HOST_IPV4="$3"
PORT="$4"
RUN_DISCOVERY_PROBE="$5"
SITE_ROOT="/omd/sites/${SITE}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

section(){ printf '\n----- %s -----\n' "$*"; }
print_limited(){
  local file="$1"
  local lines="${2:-220}"
  if [[ -s "$file" ]]; then
    local count
    count="$(wc -l < "$file" | tr -d ' ')"
    sed -n "1,${lines}p" "$file"
    if [[ "${count}" -gt "${lines}" ]]; then
      echo "... output truncated: ${count} lines total; tail follows ..."
      tail -n 80 "$file"
    fi
  else
    echo "(empty)"
  fi
}
run_root(){
  local label="$1"
  local cmd="$2"
  section "$label"
  echo "+ ${cmd}"
  bash -lc "$cmd" >"${TMP_DIR}/${label}.out" 2>"${TMP_DIR}/${label}.err"
  local rc=$?
  echo "RC=${rc}"
  echo "--- stdout ---"
  print_limited "${TMP_DIR}/${label}.out"
  echo "--- stderr ---"
  print_limited "${TMP_DIR}/${label}.err"
  return 0
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

section "site paths and process state"
if [[ ! -d "${SITE_ROOT}" ]]; then
  echo "FATAL: missing site root ${SITE_ROOT}"
  exit 0
fi
id "${SITE}" || true
ls -ld "${SITE_ROOT}" "${SITE_ROOT}/etc/check_mk" "${SITE_ROOT}/var/check_mk" "${SITE_ROOT}/tmp/check_mk" 2>&1 || true
omd version 2>&1 || true
omd status "${SITE}" 2>&1 || true
ps -ef | grep -E "cmk|nagios|rrd|apache|redis|agent-receiver" | grep -v grep || true

run_site "cmk-version" "cmk -V && cmk --version"
run_site "cmk-help-head" "cmk -h | sed -n '1,140p'"
run_site "cmk-list-hosts" "cmk -l"
run_site "cmk-list-cmk-agent-tag" "cmk --list-tag cmk-agent"
run_site "cmk-list-tcp-tag" "cmk --list-tag tcp"
run_site "cmk-list-no-agent-tag" "cmk --list-tag no-agent"
run_site "cmk-host-configuration" "cmk -D '${PLATFORM_HOST}'"
run_site "cmk-core-config-host" "cmk -N '${PLATFORM_HOST}'"
run_site "cmk-validate-config" "cmk-validate-config"

section "PlatformInit Checkmk config files"
find "${SITE_ROOT}/etc/check_mk/conf.d" -maxdepth 4 -type f | sort | sed -n '1,220p' || true
for file in "${SITE_ROOT}"/etc/check_mk/conf.d/platforminit/*.mk; do
  [[ -f "$file" ]] || continue
  echo "--- ${file} ---"
  sed -n '1,260p' "$file" || true
  echo
 done

section "local Checkmk extensions"
find "${SITE_ROOT}/local" -maxdepth 6 -type f | sort | sed -n '1,220p' || true
ls -l "${SITE_ROOT}/local/lib/nagios/plugins" 2>/dev/null || true

section "autochecks and autodiscovery state"
find "${SITE_ROOT}/var/check_mk/autochecks" -maxdepth 4 -type f -ls 2>/dev/null || true
for file in "${SITE_ROOT}/var/check_mk/autochecks/${PLATFORM_HOST}.mk" "${SITE_ROOT}/var/check_mk/autochecks"/*"/${PLATFORM_HOST}.mk"; do
  [[ -f "$file" ]] || continue
  echo "--- ${file} ---"
  sed -n '1,260p' "$file" || true
 done
find "${SITE_ROOT}/var/check_mk/autodiscovery" -maxdepth 3 -type f -ls 2>/dev/null || true

section "agent cache state"
find "${SITE_ROOT}/tmp/check_mk/cache" -maxdepth 1 -type f -ls 2>/dev/null | sed -n '1,120p' || true
if [[ -f "${SITE_ROOT}/tmp/check_mk/cache/${PLATFORM_HOST}" ]]; then
  echo "--- cache sections for ${PLATFORM_HOST} ---"
  grep -E '^<<<[^>]+>>>' "${SITE_ROOT}/tmp/check_mk/cache/${PLATFORM_HOST}" | head -n 160 || true
  echo "--- cache head ---"
  sed -n '1,160p' "${SITE_ROOT}/tmp/check_mk/cache/${PLATFORM_HOST}" || true
else
  echo "No cache file for ${PLATFORM_HOST}"
fi

run_root "pod-direct-agent-tcp-probe" "timeout 15 bash -lc 'exec 3<>/dev/tcp/${HOST_IPV4}/${PORT}; head -n 220 <&3'"
run_root "pod-direct-agent-section-list" "timeout 15 bash -lc 'exec 3<>/dev/tcp/${HOST_IPV4}/${PORT}; cat <&3' | grep -E '^<<<[^>]+>>>' | head -n 200"

run_site "cmk-fetch-agent-cmk-d" "cmk -d '${PLATFORM_HOST}'"
run_site "cmk-fetch-agent-debug-cmk-d" "cmk --debug -v -d '${PLATFORM_HOST}'"
run_site "cmk-check-dry-run-debug-vvn" "cmk --debug -vvn '${PLATFORM_HOST}'"
run_site "cmk-check-dry-run-debug-cache-vvn" "cmk --debug --cache -vvn '${PLATFORM_HOST}'"
# Avoid hard-coding Checkmk internal plugin names here. Names changed across
# versions and an unknown plugin makes the diagnostic output noisier than the
# actual datasource problem. Section parsing in the two dry-run commands above
# is enough for read-only diagnostics; state-changing discovery remains below
# behind run_discovery_probe=true.
echo "----- cmk-check-dry-run-detect-native-subset -----"
echo "SKIPPED: plugin-name-specific detect probe intentionally disabled"

section "discovery probe"
if [[ "${RUN_DISCOVERY_PROBE}" == "true" ]]; then
  echo "run_discovery_probe=true; running state-changing discovery probe without core reload"
  run_site "cmk-discovery-cache-vI" "cmk --debug --cache -vvI '${PLATFORM_HOST}'"
  run_site "cmk-discovery-live-vI" "cmk --debug -vvI '${PLATFORM_HOST}'"
  echo "post-discovery autochecks snapshot"
  for file in "${SITE_ROOT}/var/check_mk/autochecks/${PLATFORM_HOST}.mk" "${SITE_ROOT}/var/check_mk/autochecks"/*"/${PLATFORM_HOST}.mk"; do
    [[ -f "$file" ]] || continue
    echo "--- ${file} ---"
    sed -n '1,260p' "$file" || true
  done
else
  cat <<EOF
Discovery probe skipped because run_discovery_probe=false.
This keeps the workflow read-only with respect to Checkmk autochecks.
For an explicit state-changing probe, rerun the workflow with run_discovery_probe=true.
Commands that would be executed:
  cmk --debug --cache -vvI '${PLATFORM_HOST}'
  cmk --debug -vvI '${PLATFORM_HOST}'
EOF
fi

section "diagnostic summary hints"
cat <<EOF
Review order:
1. cmk -D '${PLATFORM_HOST}' -> Tags and Agent mode must show a normal Checkmk TCP agent target.
2. pod-direct-agent-section-list -> must show Linux sections such as check_mk, df, mem, uptime, lnx_if or similar.
3. cmk -d '${PLATFORM_HOST}' -> proves Checkmk's own datasource path, not only raw TCP.
4. cmk --debug -vvn '${PLATFORM_HOST}' -> proves Checkmk can process sections into services without writing autochecks.
5. autochecks snapshot -> shows whether native discovered checks are currently persisted.
EOF
CHECKMK_DIAG

section "diagnostic complete"
log "CH05.7 diagnostic collection completed. Review the uploaded operations log artifact before changing CH05.7 install/discovery logic."
