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

kubectl -n "$NAMESPACE" exec -i "$POD" -c checkmk -- bash -s -- "$CHECKMK_SITE" "$PLATFORM_HOST" <<'CHECKMK_VALIDATE'
set -euo pipefail
SITE="$1"
PLATFORM_HOST="$2"
SITE_ROOT="/omd/sites/${SITE}"

test -x "${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service"
test -f "${SITE_ROOT}/etc/check_mk/conf.d/platforminit/platforminit_hosts.mk"
test -f "${SITE_ROOT}/local/share/platforminit/README.txt"

# Synthetic PlatformInit services must be state-only until CH05.7 introduces
# native Checkmk agent metrics. This prevents broken custom graph rendering
# in service detail pages for ad-hoc Nagios perfdata. Any experimental local
# Graphing API plugin from earlier CH05.5 iterations must also be absent.
if grep -q '"has_perfdata": True' "${SITE_ROOT}/etc/check_mk/conf.d/platforminit/platforminit_hosts.mk"; then
  echo "FATAL: PlatformInit synthetic checks must not enable custom perfdata graphs" >&2
  exit 1
fi
if [[ -e "${SITE_ROOT}/local/lib/python3/cmk_addons/plugins/platforminit_synthetic" ]]; then
  echo "FATAL: stale PlatformInit synthetic Graphing API plugin is still installed" >&2
  exit 1
fi
plugin_output="$(${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service --mode ok --service 'Graph sanity' --detail 'state-only smoke')"
case "${plugin_output}" in
  *'|'*)
    echo "FATAL: PlatformInit synthetic plugin emitted perfdata unexpectedly: ${plugin_output}" >&2
    exit 1
    ;;
esac
plugin_output="$(${SITE_ROOT}/local/lib/nagios/plugins/platforminit_check_service --mode path-usage --service 'Graph sanity path' --path / --warn 80 --crit 90)"
case "${plugin_output}" in
  *'|'*)
    echo "FATAL: PlatformInit synthetic path plugin emitted perfdata unexpectedly: ${plugin_output}" >&2
    exit 1
    ;;
esac

CHECKMK_VALIDATE_DIR="$(mktemp -d)"
trap 'rm -rf "${CHECKMK_VALIDATE_DIR}"' EXIT

su - "${SITE}" -c "cmk -l" > "${CHECKMK_VALIDATE_DIR}/hosts.txt"
grep -Fx "${PLATFORM_HOST}" "${CHECKMK_VALIDATE_DIR}/hosts.txt" >/dev/null || {
  echo "FATAL: Checkmk host ${PLATFORM_HOST} is not visible in cmk -l" >&2
  cat "${CHECKMK_VALIDATE_DIR}/hosts.txt" >&2
  exit 1
}

su - "${SITE}" -c "cmk -N" > "${CHECKMK_VALIDATE_DIR}/nagios.cfg"
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
  grep -q "service_description[[:space:]]\+${service}" "${CHECKMK_VALIDATE_DIR}/nagios.cfg" || {
    echo "FATAL: expected Checkmk service is missing from generated core config: ${service}" >&2
    exit 1
  }
done

su - "${SITE}" -c "cmk -R" >/dev/null

echo "PASS: Checkmk host ${PLATFORM_HOST} is visible"
echo "PASS: PlatformInit custom service checks are present in generated core config"
echo "PASS: PlatformInit synthetic checks are state-only and do not emit custom perfdata"
echo "PASS: Stale PlatformInit graphing plugin is absent"
CHECKMK_VALIDATE
