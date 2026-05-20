#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
export KUBECONFIG

[[ ${EUID} -eq 0 ]] || die "Run as root (sudo)."

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null || die "Checkmk deployment is not ready"
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || die "No Checkmk pod found"

log "Provisioning PlatformInit Checkmk operations entrypoint in pod/${POD} host=${PLATFORM_HOST}"

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" <<'CHECKMK_DASHBOARD'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
SITE_ROOT="/omd/sites/${SITE}"
START_URL="view.py?view_name=allhosts"
HOST_STATUS_URL="view.py?view_name=hoststatus&host=${PLATFORM_HOST}"
ALL_HOSTS_URL="view.py?view_name=allhosts"
INDEX_START_URL="check_mk/index.py?start_url=view.py%3Fview_name%3Dallhosts"

# CH05.6 is deliberately conservative: Checkmk Raw/Community already provides
# useful host/service state views. The first PlatformInit operator landing page
# must show the stable all-hosts state board directly, not an empty dashboard
# selector and not a Checkmk detail view that requires additional context fields.
test -d "${SITE_ROOT}/etc/check_mk/multisite.d/wato"
test -d "${SITE_ROOT}/var/check_mk/web/cmkadmin"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
su - "${SITE}" -c "cmk -l" > "${TMP_DIR}/hosts.txt"
grep -Fx "${PLATFORM_HOST}" "${TMP_DIR}/hosts.txt" >/dev/null || {
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not visible; run CH05.5 first" >&2
  cat "${TMP_DIR}/hosts.txt" >&2
  exit 1
}

su - "${SITE}" -c "cmk -N" > "${TMP_DIR}/nagios.cfg"
service_count="$(awk -v host="${PLATFORM_HOST}" '
  $1 == "host_name" && $2 == host { in_service=1 }
  in_service && $1 == "service_description" { count++; in_service=0 }
  END { print count + 0 }
' "${TMP_DIR}/nagios.cfg")"
if [[ "${service_count}" -lt 10 ]]; then
  echo "FATAL: expected at least 10 services for ${PLATFORM_HOST}, got ${service_count}" >&2
  exit 1
fi

cat > "${SITE_ROOT}/etc/check_mk/multisite.d/wato/platforminit_operations_ui.mk" <<PLATFORMINIT_UI
# Managed by PlatformInit CH05.6.
# Make the stable Checkmk all-hosts view the deterministic operator start page.
# The URL is intentionally a Checkmk-native view rather than a fragile custom dashboard object.
start_url = '${START_URL}'
PLATFORMINIT_UI

cat > "${SITE_ROOT}/var/check_mk/web/cmkadmin/start_url.mk" <<PLATFORMINIT_USER_START
# Managed by PlatformInit CH05.6.
start_url = '${START_URL}'
PLATFORMINIT_USER_START

mkdir -p "${SITE_ROOT}/local/share/platforminit"
cat > "${SITE_ROOT}/local/share/platforminit/checkmk-operations-entrypoints.txt" <<PLATFORMINIT_LINKS
Managed by PlatformInit CH05.6

Primary operator entrypoint:
  /${SITE}/check_mk/${INDEX_START_URL}

Useful Checkmk-native views:
  All hosts state board:
    /${SITE}/check_mk/${START_URL}
  PlatformInit host status:
    /${SITE}/check_mk/${HOST_STATUS_URL}
  All hosts:
    /${SITE}/check_mk/${ALL_HOSTS_URL}
  All services:
    /${SITE}/check_mk/view.py?view_name=allservices
  Service problems:
    /${SITE}/check_mk/view.py?view_name=svcproblems

Current CH05.6 success contract:
  host=${PLATFORM_HOST}
  services>=10
  start_url=${START_URL}

Rationale:
  The Checkmk dashboard page can be empty in Community/Raw until a dashboard is
  selected or created interactively. The Checkmk service detail view requires a
  service context and crashes if it is used with only a host filter. PlatformInit
  therefore lands operators on the stable all-hosts state board, which exposes
  the UP host and OK/WARN/CRIT service counters without fragile URL context.

CH05.7 should add the Checkmk agent so this view becomes full host metrics/service discovery instead of synthetic active checks only.
PLATFORMINIT_LINKS

chown "${SITE}:${SITE}" \
  "${SITE_ROOT}/etc/check_mk/multisite.d/wato/platforminit_operations_ui.mk" \
  "${SITE_ROOT}/var/check_mk/web/cmkadmin/start_url.mk" \
  "${SITE_ROOT}/local/share/platforminit/checkmk-operations-entrypoints.txt"

# Restart the site so Multisite picks up the UI/start-url configuration deterministically.
omd restart "${SITE}" >/dev/null

# Smoke the configured operator view through the local Checkmk frontend.
for attempt in 1 2 3 4 5 6; do
  code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o /tmp/platforminit-operations-view.html -w '%{http_code}' \
    "http://127.0.0.1:5000/${SITE}/check_mk/${START_URL}" || true)"
  case "${code}" in
    200|302|303) break ;;
  esac
  sleep 5
done
case "${code}" in
  200|302|303) ;;
  *)
    echo "FATAL: PlatformInit Checkmk all-hosts operator view did not respond successfully, HTTP=${code}" >&2
    head -n 80 /tmp/platforminit-operations-view.html >&2 || true
    exit 1
    ;;
esac

# CH05.5 synthetic services are state-only. Validate every managed service
# detail page and the host-graphs view so stale graph_recipe regressions from
# earlier perfdata-enabled builds cannot slip through again.
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
  detail_file="/tmp/platforminit-service-detail-${encoded_service}.html"
  service_detail_code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o "${detail_file}" -w '%{http_code}' \
    "http://127.0.0.1:5000/${SITE}/check_mk/view.py?view_name=service&host=${PLATFORM_HOST}&service=${encoded_service}" || true)"
  case "${service_detail_code}" in
    200|302|303) ;;
    *)
      echo "FATAL: PlatformInit Checkmk service detail page returned HTTP=${service_detail_code} for service=${service}" >&2
      head -n 80 "${detail_file}" >&2 || true
      exit 1
      ;;
  esac
  if grep -Fq "graph_recipe" "${detail_file}"; then
    echo "FATAL: PlatformInit Checkmk service detail still contains graph_recipe error for service=${service}" >&2
    exit 1
  fi
done

host_graphs_file="/tmp/platforminit-host-graphs.html"
host_graphs_code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o "${host_graphs_file}" -w '%{http_code}' \
  "http://127.0.0.1:5000/${SITE}/check_mk/view.py?view_name=host_graphs&host=${PLATFORM_HOST}&site=${SITE}" || true)"
case "${host_graphs_code}" in
  200|302|303) ;;
  *)
    echo "FATAL: PlatformInit Checkmk host graphs page returned HTTP=${host_graphs_code}" >&2
    head -n 80 "${host_graphs_file}" >&2 || true
    exit 1
    ;;
esac
if grep -Fq "graph_recipe" "${host_graphs_file}"; then
  echo "FATAL: PlatformInit Checkmk host graphs page still contains graph_recipe error" >&2
  exit 1
fi

echo "PASS: PlatformInit Checkmk operator start URL set to ${START_URL}"
echo "PASS: PlatformInit Checkmk operator view responds with HTTP=${code}"
echo "PASS: ${PLATFORM_HOST} has ${service_count} generated services"
echo "PASS: PlatformInit managed service detail pages have no graph_recipe errors"
echo "PASS: PlatformInit host graphs page has no graph_recipe errors"
CHECKMK_DASHBOARD

log "Checkmk operations all-hosts entrypoint provisioned"
