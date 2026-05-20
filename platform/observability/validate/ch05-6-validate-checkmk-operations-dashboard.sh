#!/usr/bin/env bash
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
PLATFORM_HOST="${PLATFORM_HOST:-platforminit-dev-01}"
export KUBECONFIG

kubectl -n "$NAMESPACE" rollout status deployment/checkmk --timeout=180s >/dev/null
POD="$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=checkmk -o jsonpath='{.items[0].metadata.name}')"
[[ -n "$POD" ]] || { echo "FATAL: no Checkmk pod found" >&2; exit 1; }

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" <<'CHECKMK_DASHBOARD_VALIDATE'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
SITE_ROOT="/omd/sites/${SITE}"
START_URL="view.py?view_name=allhosts"
HOST_STATUS_URL="view.py?view_name=hoststatus&host=${PLATFORM_HOST}"

UI_FILE="${SITE_ROOT}/etc/check_mk/multisite.d/wato/platforminit_operations_ui.mk"
USER_START_FILE="${SITE_ROOT}/var/check_mk/web/cmkadmin/start_url.mk"
ENTRYPOINTS="${SITE_ROOT}/local/share/platforminit/checkmk-operations-entrypoints.txt"

test -f "${UI_FILE}"
test -f "${USER_START_FILE}"
test -f "${ENTRYPOINTS}"
grep -F "start_url = '${START_URL}'" "${UI_FILE}" >/dev/null
grep -F "start_url = '${START_URL}'" "${USER_START_FILE}" >/dev/null
grep -F "view.py?view_name=allhosts" "${ENTRYPOINTS}" >/dev/null
grep -F "view.py?view_name=hoststatus&host=${PLATFORM_HOST}" "${ENTRYPOINTS}" >/dev/null

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
su - "${SITE}" -c "cmk -l" > "${TMP_DIR}/hosts.txt"
grep -Fx "${PLATFORM_HOST}" "${TMP_DIR}/hosts.txt" >/dev/null || {
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not visible" >&2
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

code="$(curl -ksS -H 'X-Remote-User: cmkadmin' -o /tmp/platforminit-operations-view-validate.html -w '%{http_code}' \
  "http://127.0.0.1:5000/${SITE}/check_mk/${START_URL}" || true)"
case "${code}" in
  200|302|303) ;;
  *)
    echo "FATAL: operator all-hosts view returned HTTP=${code}" >&2
    head -n 80 /tmp/platforminit-operations-view-validate.html >&2 || true
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

echo "PASS: PlatformInit Checkmk start URL is configured"
echo "PASS: PlatformInit Checkmk all-hosts operator view responds with HTTP=${code}"
echo "PASS: ${PLATFORM_HOST} is visible with ${service_count} generated services"
echo "PASS: PlatformInit managed service detail pages have no graph_recipe errors"
echo "PASS: PlatformInit host graphs page has no graph_recipe errors"
CHECKMK_DASHBOARD_VALIDATE
