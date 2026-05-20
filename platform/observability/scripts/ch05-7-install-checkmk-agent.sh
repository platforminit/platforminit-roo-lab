#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
CHECKMK_AGENT_PORT="${CHECKMK_AGENT_PORT:-6556}"
CHECKMK_AGENT_ALLOW_CIDRS="${CHECKMK_AGENT_ALLOW_CIDRS:-}"
export KUBECONFIG

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."
[[ -f "$KUBECONFIG" ]] || die "Missing kubeconfig at ${KUBECONFIG}"
command -v kubectl >/dev/null || die "kubectl is required"
command -v systemctl >/dev/null || die "systemctl is required"

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null || die "Checkmk deployment is not ready"
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "No Checkmk pod found"

HOST_IPV4="${HOST_IPV4:-$(hostname -I | awk '{print $1}') }"
HOST_IPV4="${HOST_IPV4%% }"
[[ -n "$HOST_IPV4" ]] || die "Could not resolve host IPv4 address"

log "Installing Checkmk Linux agent on ${PLATFORM_HOST} (${HOST_IPV4}) from Checkmk site ${CHECKMK_SITE}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

install_agent_script_from_deb() {
  local deb_path="$1"
  local extract_dir="${TMP_DIR}/agent-deb-extract"

  rm -rf "$extract_dir"
  mkdir -p "$extract_dir"
  dpkg-deb -x "$deb_path" "$extract_dir"

  local extracted_agent=""
  extracted_agent="$(find "$extract_dir" -type f \( -path '*/usr/bin/check_mk_agent' -o -path '*/usr/bin/check-mk-agent' \) | sort | head -n1)"
  [[ -n "$extracted_agent" ]] || die "Could not extract check_mk_agent from architecture-mismatched Checkmk .deb"

  log "Installing architecture-independent Checkmk agent script from extracted package payload: ${extracted_agent}"
  install -m 0755 "$extracted_agent" /usr/bin/check_mk_agent
}

install_agent_script_from_site() {
  log "Falling back to site-provided Linux agent script"
  AGENT_SCRIPT_PATH="$(kubectl -n "$NAMESPACE" exec "$POD" -c checkmk -- bash -lc "find /omd/sites/${CHECKMK_SITE}/share/check_mk/agents -maxdepth 3 -type f \( -name 'check_mk_agent.linux' -o -name 'check_mk_agent' \) 2>/dev/null | sort | head -n1" | tr -d '\r')"
  [[ -n "$AGENT_SCRIPT_PATH" ]] || die "No Checkmk Linux agent package or script found in Checkmk site"
  log "Using Checkmk agent script from site: ${AGENT_SCRIPT_PATH}"
  kubectl -n "$NAMESPACE" exec "$POD" -c checkmk -- bash -lc "cat '${AGENT_SCRIPT_PATH}'" > /usr/bin/check_mk_agent
  chmod 0755 /usr/bin/check_mk_agent
}

AGENT_DEB_PATH="$(kubectl -n "$NAMESPACE" exec "$POD" -c checkmk -- bash -lc "find /omd/sites/${CHECKMK_SITE}/share/check_mk/agents -maxdepth 3 -type f -name 'check-mk-agent_*.deb' 2>/dev/null | sort -V | tail -n1" | tr -d '\r')"

if [[ -n "$AGENT_DEB_PATH" ]]; then
  log "Found Checkmk agent package in site: ${AGENT_DEB_PATH}"
  kubectl -n "$NAMESPACE" exec "$POD" -c checkmk -- bash -lc "cat '${AGENT_DEB_PATH}'" > "${TMP_DIR}/check-mk-agent.deb"
  [[ -s "${TMP_DIR}/check-mk-agent.deb" ]] || die "Downloaded Checkmk agent package is empty"

  host_arch="$(dpkg --print-architecture)"
  package_arch="$(dpkg-deb -f "${TMP_DIR}/check-mk-agent.deb" Architecture 2>/dev/null || true)"
  [[ -n "$package_arch" ]] || die "Could not read Checkmk agent package architecture"
  log "Host architecture is ${host_arch}; Checkmk site agent package architecture is ${package_arch}"

  if [[ "$package_arch" == "$host_arch" || "$package_arch" == "all" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y "${TMP_DIR}/check-mk-agent.deb"
  else
    log "Checkmk site package architecture does not match host architecture; avoiding apt install and using agent script fallback"
    install_agent_script_from_deb "${TMP_DIR}/check-mk-agent.deb"
  fi
else
  log "No Checkmk agent .deb package found in site"
  install_agent_script_from_site
fi

if ! command -v check_mk_agent >/dev/null; then
  if [[ -x /usr/bin/check_mk_agent ]]; then
    :
  else
    die "check_mk_agent was not installed"
  fi
fi

# Some Checkmk agent packages provide the socket unit; script fallback does not.
# Keep deterministic systemd socket units so the agent is reachable on TCP/6556.
if ! systemctl list-unit-files --type=socket --no-legend 'check-mk-agent.socket' 2>/dev/null | awk '{print $1}' | grep -Fxq 'check-mk-agent.socket'; then
  log "Creating Checkmk agent systemd socket units"
  cat > /etc/systemd/system/check-mk-agent@.service <<'UNIT'
[Unit]
Description=Checkmk agent connection from %I
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/check_mk_agent
StandardInput=socket
StandardOutput=socket
StandardError=journal
User=root
Group=root
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=read-only
ProtectSystem=full
UNIT

  cat > /etc/systemd/system/check-mk-agent.socket <<UNIT
[Unit]
Description=Checkmk agent socket
After=network.target

[Socket]
ListenStream=${CHECKMK_AGENT_PORT}
Accept=yes

[Install]
WantedBy=sockets.target
UNIT
fi

systemctl daemon-reload
systemctl enable --now check-mk-agent.socket >/dev/null
systemctl restart check-mk-agent.socket
sleep 2
systemctl is-active --quiet check-mk-agent.socket || die "check-mk-agent.socket is not active"

if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi '^Status: active'; then
  log "Configuring UFW allow rules for Checkmk agent port ${CHECKMK_AGENT_PORT}"
  mapfile -t detected_pod_cidrs < <(kubectl get nodes -o jsonpath='{range .items[*]}{range .spec.podCIDRs[*]}{.}{"\n"}{end}{.spec.podCIDR}{"\n"}{end}' 2>/dev/null | sed '/^$/d' | sort -u)
  allow_cidrs=()
  if [[ -n "$CHECKMK_AGENT_ALLOW_CIDRS" ]]; then
    # shellcheck disable=SC2206
    allow_cidrs=($CHECKMK_AGENT_ALLOW_CIDRS)
  else
    allow_cidrs=("${detected_pod_cidrs[@]}")
  fi
  allow_cidrs+=("127.0.0.1/32" "${HOST_IPV4}/32")
  for cidr in "${allow_cidrs[@]}"; do
    [[ -n "$cidr" ]] || continue
    ufw allow from "$cidr" to any port "$CHECKMK_AGENT_PORT" proto tcp comment 'PlatformInit CH05.7 Checkmk agent' >/dev/null || true
  done
else
  log "UFW is not active or not installed; skipping firewall rule reconciliation"
fi

if ! ss -ltn "sport = :${CHECKMK_AGENT_PORT}" | grep -q ":${CHECKMK_AGENT_PORT}"; then
  ss -ltn >&2 || true
  die "Checkmk agent is not listening on TCP/${CHECKMK_AGENT_PORT}"
fi

log "Validating local Checkmk agent output"
if ! timeout 10 bash -lc "exec 3<>/dev/tcp/127.0.0.1/${CHECKMK_AGENT_PORT}; head -n 40 <&3" > "${TMP_DIR}/agent-local.txt"; then
  die "Could not read Checkmk agent output locally on 127.0.0.1:${CHECKMK_AGENT_PORT}"
fi
grep -F '<<<check_mk>>>' "${TMP_DIR}/agent-local.txt" >/dev/null || die "Local Checkmk agent output does not contain <<<check_mk>>> section"

log "Validating Checkmk pod can reach host agent at ${HOST_IPV4}:${CHECKMK_AGENT_PORT}"
kubectl -n "$NAMESPACE" exec "$POD" -c checkmk -- bash -s -- "$HOST_IPV4" "$CHECKMK_AGENT_PORT" <<'CHECK_AGENT_REACHABILITY'
set -euo pipefail
HOST_IPV4="$1"
PORT="$2"
TMP_OUT="/tmp/platforminit-agent-reachability.txt"
if ! timeout 15 bash -lc "exec 3<>/dev/tcp/${HOST_IPV4}/${PORT}; head -n 80 <&3" > "${TMP_OUT}"; then
  echo "FATAL: Checkmk pod cannot read agent output from ${HOST_IPV4}:${PORT}" >&2
  exit 1
fi
grep -F '<<<check_mk>>>' "${TMP_OUT}" >/dev/null || {
  echo "FATAL: Remote agent output does not contain <<<check_mk>>> section" >&2
  head -n 40 "${TMP_OUT}" >&2 || true
  exit 1
}
CHECK_AGENT_REACHABILITY

log "Discovering native Checkmk agent services for ${PLATFORM_HOST}"
kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" "$HOST_IPV4" "$CHECKMK_AGENT_PORT" <<'CHECKMK_DISCOVERY'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
HOST_IPV4="$3"
PORT="$4"
SITE_ROOT="/omd/sites/${SITE}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

test -d "${SITE_ROOT}" || { echo "FATAL: missing Checkmk site ${SITE}" >&2; exit 1; }

mkdir -p "${SITE_ROOT}/etc/check_mk/conf.d/platforminit" "${SITE_ROOT}/tmp/check_mk/cache"

# Previous CH05.7 iterations tried to force the native-agent address by writing
# raw Checkmk host-attribute overlays. That proved brittle and could make
# `cmk -N` fail before discovery even started. Remove that overlay and keep
# CH05.7 scoped to the agent cache/discovery path.
rm -f "${SITE_ROOT}/etc/check_mk/conf.d/platforminit/zz_platforminit_agent_address.mk"

write_agent_cache() {
  local cache_file="${SITE_ROOT}/tmp/check_mk/cache/${PLATFORM_HOST}"
  if ! timeout 20 bash -lc "exec 3<>/dev/tcp/${HOST_IPV4}/${PORT}; cat <&3" > "${TMP_DIR}/agent-cache.raw"; then
    echo "FATAL: cannot refresh Checkmk agent cache from ${HOST_IPV4}:${PORT}" >&2
    exit 1
  fi
  grep -F '<<<check_mk>>>' "${TMP_DIR}/agent-cache.raw" >/dev/null || {
    echo "FATAL: direct agent cache refresh did not contain <<<check_mk>>>" >&2
    head -n 80 "${TMP_DIR}/agent-cache.raw" >&2 || true
    exit 1
  }
  install -m 0644 "${TMP_DIR}/agent-cache.raw" "${cache_file}"
  chown "${SITE}:${SITE}" "${cache_file}"
}

dump_checkmk_context() {
  local label="$1"
  local cmd="$2"
  echo "--- ${label} command ---" >&2
  echo "${cmd}" >&2
  echo "--- ${label} stdout ---" >&2
  head -n 200 "${TMP_DIR}/${label}.out" >&2 || true
  echo "--- ${label} stderr ---" >&2
  head -n 200 "${TMP_DIR}/${label}.err" >&2 || true
  echo "--- cmk -D ${PLATFORM_HOST} ---" >&2
  su - "${SITE}" -c "cmk -D '${PLATFORM_HOST}'" >&2 || true
  echo "--- cmk-validate-config ---" >&2
  su - "${SITE}" -c "cmk-validate-config" >&2 || true
  echo "--- direct TCP agent probe from Checkmk pod ---" >&2
  timeout 10 bash -lc "exec 3<>/dev/tcp/${HOST_IPV4}/${PORT}; head -n 80 <&3" >&2 || true
  echo "--- stale CH05.7 address overlay should be absent ---" >&2
  ls -l "${SITE_ROOT}/etc/check_mk/conf.d/platforminit/zz_platforminit_agent_address.mk" >&2 || true
}

run_site_cmd() {
  local label="$1"
  shift
  local cmd="$*"
  if ! su - "${SITE}" -c "${cmd}" > "${TMP_DIR}/${label}.out" 2> "${TMP_DIR}/${label}.err"; then
    echo "FATAL: Checkmk command failed: ${cmd}" >&2
    dump_checkmk_context "${label}" "${cmd}"
    exit 1
  fi
}

run_site_cmd_warn() {
  local label="$1"
  shift
  local cmd="$*"
  if ! su - "${SITE}" -c "${cmd}" > "${TMP_DIR}/${label}.out" 2> "${TMP_DIR}/${label}.err"; then
    echo "WARN: non-fatal Checkmk command failed: ${cmd}" >&2
    dump_checkmk_context "${label}" "${cmd}"
    return 1
  fi
}

# CH05.7 already proved direct pod-to-host TCP reachability before entering this
# block. CH05.5 must also expose the host as a TCP Checkmk agent target via the
# explicit raw `tcp` host tag; otherwise Checkmk 2.5 fetches only piggyback data.
# Refresh the Checkmk agent cache from the deterministic IP path and run discovery
# from cache so DNS/IPv6 resolver drift cannot change the data source path.
write_agent_cache

run_site_cmd config-validation "cmk-validate-config"
run_site_cmd cmk-host-list "cmk -l"
cp "${TMP_DIR}/cmk-host-list.out" "${TMP_DIR}/hosts.txt"
grep -Fx "${PLATFORM_HOST}" "${TMP_DIR}/hosts.txt" >/dev/null || {
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not defined; run CH05.5 first" >&2
  cat "${TMP_DIR}/hosts.txt" >&2
  exit 1
}

su - "${SITE}" -c "cmk -D '${PLATFORM_HOST}'" > "${TMP_DIR}/host-diagnostics.txt" 2>&1 || true
if ! grep -Eq 'Type of agent:[[:space:]]*TCP|Normal Checkmk agent' "${TMP_DIR}/host-diagnostics.txt"; then
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not a TCP Checkmk agent target; run the fixed CH05.5 host model first" >&2
  echo "Expected CH05.5 to write the host with explicit raw tags: cmk-agent|tcp|prod|lan" >&2
  echo "--- cmk -D ${PLATFORM_HOST} ---" >&2
  cat "${TMP_DIR}/host-diagnostics.txt" >&2 || true
  exit 1
fi

# Prove Checkmk's own datasource can fetch and parse the agent before discovery.
# Do not require native service status lines here: before the first successful
# discovery there are intentionally no native Linux autochecks yet.
run_site_cmd cmk-agent-fetch "cmk -d '${PLATFORM_HOST}'"

section_hits="$(grep -Ec '^<<<(df_v2|mem|cpu|uptime|lnx_if|systemd_units|diskstat|kernel)' "${TMP_DIR}/cmk-agent-fetch.out" || true)"
if [[ "${section_hits}" -lt 4 ]]; then
  echo "FATAL: Checkmk fetched the agent but did not expose enough native Linux sections, got ${section_hits}" >&2
  echo "--- cmk -d ${PLATFORM_HOST} stdout ---" >&2
  head -n 240 "${TMP_DIR}/cmk-agent-fetch.out" >&2 || true
  echo "--- cmk -d ${PLATFORM_HOST} stderr ---" >&2
  head -n 160 "${TMP_DIR}/cmk-agent-fetch.err" >&2 || true
  echo "--- raw agent cache sections ---" >&2
  grep -E '^<<<[^>]+>>>' "${SITE_ROOT}/tmp/check_mk/cache/${PLATFORM_HOST}" | head -n 120 >&2 || true
  echo "--- cmk -D ${PLATFORM_HOST} ---" >&2
  cat "${TMP_DIR}/host-diagnostics.txt" >&2 || true
  exit 1
fi

run_site_cmd_warn cmk-agent-parse-debug "cmk --debug --cache -vvn '${PLATFORM_HOST}'" || true

# Do not restrict the initial discovery to a hand-picked plugin list. Checkmk
# 2.5 service names/check plug-in names are version-specific; full discovery is
# safer and matches the documented cmk -I flow. The --cache flag makes Checkmk
# use the freshly written cache entry for PLATFORM_HOST.
run_site_cmd cmk-discovery "cmk --cache -vI '${PLATFORM_HOST}'"

if ! run_site_cmd_warn cmk-reload-after-discovery "cmk -R"; then
  echo "WARN: cmk -R failed after discovery; trying cmk -O as reload fallback" >&2
  run_site_cmd cmk-reload-after-discovery-fallback "cmk -O"
fi

# Run checks once from the same deterministic cache path so Livestatus/UI has
# fresh native-agent state before validation.
write_agent_cache
run_site_cmd_warn cmk-check-from-cache "cmk --cache -nv '${PLATFORM_HOST}'" || true
run_site_cmd cmk-core-config "cmk -N"
cp "${TMP_DIR}/cmk-core-config.out" "${TMP_DIR}/nagios.cfg"

service_count="$(awk -v host="${PLATFORM_HOST}" '
  $1 == "define" && $2 == "service" { in_service=1; has_host=0 }
  in_service && $1 == "host_name" && $2 == host { has_host=1 }
  in_service && has_host && $1 == "service_description" { count++ }
  in_service && $1 == "}" { in_service=0 }
  END { print count + 0 }
' "${TMP_DIR}/nagios.cfg")"

if [[ "${service_count}" -lt 15 ]]; then
  echo "FATAL: expected native agent discovery to increase ${PLATFORM_HOST} service count to at least 15, got ${service_count}" >&2
  grep -A5 -B2 -E "host_name[[:space:]]+${PLATFORM_HOST}|service_description" "${TMP_DIR}/nagios.cfg" | head -n 200 >&2 || true
  echo "--- cmk -D ${PLATFORM_HOST} ---" >&2
  cat "${TMP_DIR}/host-diagnostics.txt" >&2 || true
  echo "--- discovery stdout ---" >&2
  head -n 240 "${TMP_DIR}/cmk-discovery.out" >&2 || true
  echo "--- discovery stderr ---" >&2
  head -n 240 "${TMP_DIR}/cmk-discovery.err" >&2 || true
  echo "--- autochecks ---" >&2
  find "${SITE_ROOT}/var/check_mk/autochecks" -maxdepth 2 -type f -name "${PLATFORM_HOST}.mk" -print -exec sed -n '1,220p' {} \; >&2 || true
  exit 1
fi

native_hits="$(grep -Ec 'service_description[[:space:]]+(CPU|Memory|Filesystem|Uptime|Interface|Kernel|TCP|Check_MK|Disk IO|Memory and swap|Filesystem /)' "${TMP_DIR}/nagios.cfg" || true)"
if [[ "${native_hits}" -lt 3 ]]; then
  echo "FATAL: expected at least 3 native Linux agent services in generated Checkmk config, got ${native_hits}" >&2
  grep -E 'service_description' "${TMP_DIR}/nagios.cfg" | head -n 160 >&2 || true
  echo "--- cmk -D ${PLATFORM_HOST} ---" >&2
  cat "${TMP_DIR}/host-diagnostics.txt" >&2 || true
  echo "--- discovery stdout ---" >&2
  head -n 240 "${TMP_DIR}/cmk-discovery.out" >&2 || true
  echo "--- discovery stderr ---" >&2
  head -n 240 "${TMP_DIR}/cmk-discovery.err" >&2 || true
  echo "--- autochecks ---" >&2
  find "${SITE_ROOT}/var/check_mk/autochecks" -maxdepth 2 -type f -name "${PLATFORM_HOST}.mk" -print -exec sed -n '1,220p' {} \; >&2 || true
  exit 1
fi

mkdir -p "${SITE_ROOT}/local/share/platforminit"
cat > "${SITE_ROOT}/local/share/platforminit/checkmk-agent-discovery.txt" <<EOF_DISCOVERY
Managed by PlatformInit CH05.7

Host:
  ${PLATFORM_HOST}

Discovery model:
  Native Checkmk Linux agent pull mode on TCP/6556

Implementation note:
  Discovery uses a freshly refreshed Checkmk agent cache populated from the
  directly verified ${HOST_IPV4}:${PORT} path. This avoids hostname resolver
  drift while preserving the PlatformInit Checkmk host object name.

Validation:
  service_count=${service_count}
  native_service_matches=${native_hits}

Synthetic CH05.5 checks remain state-only. Real metric graphs are provided by
native Checkmk agent discovery from this layer onward.
EOF_DISCOVERY
chown "${SITE}:${SITE}" "${SITE_ROOT}/local/share/platforminit/checkmk-agent-discovery.txt"

echo "PASS: Checkmk agent cache refreshed from ${HOST_IPV4}:${PORT} for ${PLATFORM_HOST}"
echo "PASS: Native agent discovery generated ${service_count} total services with ${native_hits} native service matches"
CHECKMK_DISCOVERY
log "CH05.7 Checkmk Linux agent installation and native service discovery completed"
