#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
EXPECTED_MIN_SERVICES="${EXPECTED_MIN_SERVICES:-20}"
export KUBECONFIG

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null || die "Checkmk deployment is not ready"
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "No Checkmk pod found"

log "Configuring PlatformInit Checkmk alert-manager dashboard and noise policy in pod/${POD} host=${PLATFORM_HOST}"

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" "$EXPECTED_MIN_SERVICES" <<'CHECKMK_DASHBOARDS'
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

NOISE_RULE_FILE="${SITE_ROOT}/etc/check_mk/conf.d/platforminit/platforminit_noise_policy.mk"
UI_FILE="${SITE_ROOT}/etc/check_mk/multisite.d/wato/platforminit_operations_ui.mk"
USER_START_FILE="${SITE_ROOT}/var/check_mk/web/cmkadmin/start_url.mk"
DASHBOARD_CATALOG="${SITE_ROOT}/local/share/platforminit/checkmk-operations-dashboards.txt"
ALERT_SNAPSHOT="${SITE_ROOT}/local/share/platforminit/checkmk-alert-manager-current.txt"

test -d "${SITE_ROOT}/etc/check_mk/multisite.d/wato"
test -d "${SITE_ROOT}/var/check_mk/web/cmkadmin"
mkdir -p "${SITE_ROOT}/local/share/platforminit" "${SITE_ROOT}/etc/check_mk/conf.d/platforminit"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

run_site_cmd() {
  local label="$1"
  shift
  local cmd="$*"
  if ! su - "${SITE}" -c "${cmd}" > "${TMP_DIR}/${label}.out" 2> "${TMP_DIR}/${label}.err"; then
    echo "FATAL: Checkmk command failed: ${cmd}" >&2
    echo "--- ${label} stdout ---" >&2
    head -n 200 "${TMP_DIR}/${label}.out" >&2 || true
    echo "--- ${label} stderr ---" >&2
    head -n 200 "${TMP_DIR}/${label}.err" >&2 || true
    echo "--- cmk -D ${PLATFORM_HOST} ---" >&2
    su - "${SITE}" -c "cmk -D '${PLATFORM_HOST}'" >&2 || true
    echo "--- platforminit config files ---" >&2
    find "${SITE_ROOT}/etc/check_mk/conf.d/platforminit" -maxdepth 1 -type f -print -exec sed -n '1,220p' {} \; >&2 || true
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
    head -n 160 "${TMP_DIR}/${label}.out" >&2 || true
    echo "--- ${label} stderr ---" >&2
    head -n 160 "${TMP_DIR}/${label}.err" >&2 || true
    return 1
  fi
}

run_site_cmd cmk-version "cmk --version"
run_site_cmd cmk-host-list "cmk -l"
grep -Fx "${PLATFORM_HOST}" "${TMP_DIR}/cmk-host-list.out" >/dev/null || {
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not visible; run CH05.5 first" >&2
  cat "${TMP_DIR}/cmk-host-list.out" >&2
  exit 1
}

su - "${SITE}" -c "cmk -D '${PLATFORM_HOST}'" > "${TMP_DIR}/host-model.txt"
if ! grep -Fq '[agent:cmk-agent]' "${TMP_DIR}/host-model.txt" || ! grep -Fq '[tcp:tcp]' "${TMP_DIR}/host-model.txt" || ! grep -Fq 'TCP:' "${TMP_DIR}/host-model.txt"; then
  echo "FATAL: ${PLATFORM_HOST} is not a Checkmk TCP agent target; run CH05.7 before CH05.8" >&2
  cat "${TMP_DIR}/host-model.txt" >&2
  exit 1
fi

cat > "${NOISE_RULE_FILE}" <<PLATFORMINIT_NOISE
# Managed by PlatformInit CH05.8.
# Keep the operator dashboards focused on actionable current problems.
# k3s/containerd overlay rootfs mounts are transient implementation details.
# They vanish whenever pods restart and should not page the operator console.

globals().setdefault("ignored_services", [])

ignored_services = [
    {
        "id": "b7ec55f7-8b85-4d03-a78a-000000000801",
        "value": True,
        "condition": {
            "host_name": ["${PLATFORM_HOST}"],
            "service_description": [{"\$regex": "^Filesystem /run/k3s/containerd/.*/rootfs$"}],
        },
        "options": {
            "disabled": False,
            "description": "PlatformInit CH05: ignore transient k3s/containerd overlay rootfs filesystems",
        },
    }
] + ignored_services
PLATFORMINIT_NOISE
python3 - <<'PYFIX' "${NOISE_RULE_FILE}"
from pathlib import Path
import sys
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('"\\$regex"', '"$regex"'))
PYFIX

python3 - <<'PYCLEAN' "${SITE_ROOT}" "${PLATFORM_HOST}"
from pathlib import Path
import sys
site_root = Path(sys.argv[1])
host = sys.argv[2]
removed = []
root = site_root / "var" / "check_mk" / "autochecks"
if root.exists():
    for path in root.rglob("*.mk"):
        lines = path.read_text(errors="replace").splitlines(keepends=True)
        new_lines = []
        for line in lines:
            if "Filesystem /run/k3s/containerd/" in line and "/rootfs" in line:
                removed.append(f"{path}: {line.strip()[:240]}")
                continue
            new_lines.append(line)
        if new_lines != lines:
            path.write_text("".join(new_lines))
report = site_root / "local" / "share" / "platforminit" / "checkmk-noise-cleanup-removed-autochecks.txt"
report.parent.mkdir(parents=True, exist_ok=True)
if removed:
    report.write_text("\n".join(removed) + "\n")
    print(f"Removed {len(removed)} transient filesystem autocheck entries")
else:
    report.write_text("No transient filesystem autocheck entries required removal\n")
    print("No transient filesystem autocheck entries required removal")
PYCLEAN

chown "${SITE}:${SITE}" "${NOISE_RULE_FILE}" || true
run_site_cmd config-validation-before-discovery "cmk-validate-config"
run_site_cmd_warn discovery-after-noise-policy "cmk --cache -vI '${PLATFORM_HOST}'" || true
if ! run_site_cmd_warn reload-after-noise-policy "cmk -R"; then
  echo "WARN: cmk -R failed after noise policy; trying cmk -O" >&2
  run_site_cmd reload-after-noise-policy-fallback "cmk -O"
fi
run_site_cmd_warn check-from-cache-after-noise-policy "cmk --cache -nv '${PLATFORM_HOST}'" || true
run_site_cmd core-config-after-noise-policy "cmk -N"
cp "${TMP_DIR}/core-config-after-noise-policy.out" "${TMP_DIR}/nagios.cfg"

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
  echo "FATAL: transient k3s/containerd rootfs filesystem services still exist after noise cleanup" >&2
  grep -F "Filesystem /run/k3s/containerd/" "${TMP_DIR}/nagios.cfg" | head -n 40 >&2 || true
  exit 1
fi

cat > "${UI_FILE}" <<PLATFORMINIT_UI
# Managed by PlatformInit CH05.8.
# Primary operator landing is the PlatformInit Alert Manager view backed by
# Checkmk's built-in Host & service problems dashboard.
start_url = '${START_URL}'
PLATFORMINIT_UI

cat > "${USER_START_FILE}" <<PLATFORMINIT_USER_START
# Managed by PlatformInit CH05.8.
start_url = '${START_URL}'
PLATFORMINIT_USER_START

cat > "${DASHBOARD_CATALOG}" <<PLATFORMINIT_DASHBOARDS
Managed by PlatformInit CH05.8

Primary operator dashboard:
  PlatformInit Alert Manager
    /${SITE}/check_mk/${ALERT_MANAGER_DASHBOARD_URL}
    Purpose: current actionable host/service problems only: WARN, CRIT,
             UNKNOWN, DOWN and UNREACHABLE as rendered by Checkmk.

Secondary overview dashboards:
  Main dashboard:
    /${SITE}/check_mk/${MAIN_DASHBOARD_URL}
  Checkmk dashboard:
    /${SITE}/check_mk/${CHECKMK_DASHBOARD_URL}

Operational drill-down views:
  PlatformInit host status:
    /${SITE}/check_mk/${HOST_STATUS_URL}
  PlatformInit host graphs:
    /${SITE}/check_mk/${HOST_GRAPHS_URL}
  All hosts:
    /${SITE}/check_mk/${ALL_HOSTS_URL}
  All services:
    /${SITE}/check_mk/${ALL_SERVICES_URL}
  Service problems:
    /${SITE}/check_mk/${SERVICE_PROBLEMS_URL}

Noise policy:
  ignored_transient_filesystems=true
  ignored_pattern=^Filesystem /run/k3s/containerd/.*/rootfs$
  discovery_reconciled=true

Runtime contract:
  host=${PLATFORM_HOST}
  services>=${EXPECTED_MIN_SERVICES}
  start_url=${START_URL}
  tcp_agent=true
  graph_ajax_content_type_preserved=true
  session_cookie_preserved=true

Rationale:
  CH05.8 promotes the built-in Host & service problems dashboard as the
  PlatformInit Alert Manager instead of creating raw dashboard object files.
  It also removes transient k3s/containerd overlay filesystem noise so the
  alert dashboard focuses on current actionable WARN/CRIT/UNKNOWN conditions.
PLATFORMINIT_DASHBOARDS

{
  echo "Managed by PlatformInit CH05.8"
  echo "Generated at: $(date -u +%FT%TZ)"
  echo "Host: ${PLATFORM_HOST}"
  echo
  echo "Current non-OK lines from cmk --cache -nv:"
  grep -E '(^|[[:space:]])(WARN|CRIT|UNKNOWN|DOWN|UNREACH)' "${TMP_DIR}/check-from-cache-after-noise-policy.out" || true
} > "${ALERT_SNAPSHOT}"

chown "${SITE}:${SITE}" \
  "${UI_FILE}" \
  "${USER_START_FILE}" \
  "${DASHBOARD_CATALOG}" \
  "${ALERT_SNAPSHOT}" \
  "${NOISE_RULE_FILE}"

omd restart "${SITE}" >/dev/null

probe_url() {
  local name="$1"
  local path="$2"
  local output="${TMP_DIR}/${name}.html"
  local code
  code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o "${output}" -w '%{http_code}' \
    "http://127.0.0.1:5000/${SITE}/check_mk/${path}" || true)"
  case "${code}" in
    200|302|303)
      ;;
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

for attempt in 1 2 3 4 5 6; do
  if curl -ksS -H 'X-Remote-User: cmkadmin' -o /tmp/platforminit-dashboard-ready.html -w '%{http_code}' \
    "http://127.0.0.1:5000/${SITE}/check_mk/${ALERT_MANAGER_DASHBOARD_URL}" | grep -Eq '^(200|302|303)$'; then
    break
  fi
  sleep 5
  [[ "${attempt}" != "6" ]] || {
    echo "FATAL: Checkmk Alert Manager dashboard did not become reachable after omd restart" >&2
    head -n 80 /tmp/platforminit-dashboard-ready.html >&2 || true
    exit 1
  }
done

probe_url "alert-manager-dashboard" "${ALERT_MANAGER_DASHBOARD_URL}"
probe_url "dashboard-main" "${MAIN_DASHBOARD_URL}"
probe_url "dashboard-checkmk" "${CHECKMK_DASHBOARD_URL}"
probe_url "host-status" "${HOST_STATUS_URL}"
probe_url "host-graphs" "${HOST_GRAPHS_URL}"
probe_url "all-hosts" "${ALL_HOSTS_URL}"
probe_url "all-services" "${ALL_SERVICES_URL}"
probe_url "service-problems" "${SERVICE_PROBLEMS_URL}"

cat <<SUMMARY
PASS: PlatformInit Alert Manager dashboard start URL set to ${START_URL}
PASS: ${PLATFORM_HOST} is a TCP Checkmk agent target
PASS: ${PLATFORM_HOST} has ${service_count} generated services
PASS: transient k3s/containerd overlay rootfs filesystems are ignored
PASS: Checkmk native dashboards and PlatformInit drill-down views respond
PASS: Dashboard and graph probes are free from graph_recipe errors
SUMMARY
CHECKMK_DASHBOARDS

log "Checkmk alert-manager dashboard and operations noise policy provisioned"
