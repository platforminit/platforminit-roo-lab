#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
CHECKMK_SITE="${CHECKMK_SITE:-cmk}"
CHECKMK_ADMIN_PASSWORD="${CHECKMK_ADMIN_PASSWORD:-${CMK_PASSWORD:-}}"
CHECKMK_REMOTE_USER_HEADER="${CHECKMK_REMOTE_USER_HEADER:-X-Remote-User}"
OBSERVABILITY_STORAGE_ROOT="${OBSERVABILITY_STORAGE_ROOT:-/srv/observability/data}"
export KUBECONFIG
[[ -n "${BASE_DOMAIN}" ]] || die "Missing BASE_DOMAIN. Set PLATFORM_BASE_DOMAIN; do not hardcode domains in CH05."
need kubectl
need openssl
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null

log "Ensuring CH05 Checkmk storage directory under ${OBSERVABILITY_STORAGE_ROOT}/checkmk"
mkdir -p "${OBSERVABILITY_STORAGE_ROOT}/checkmk"
chmod 0775 "${OBSERVABILITY_STORAGE_ROOT}" "${OBSERVABILITY_STORAGE_ROOT}/checkmk" 2>/dev/null || true
if ! findmnt -T /srv/observability >/dev/null 2>&1; then
  log "WARN: /srv/observability is not a dedicated mountpoint; Checkmk data will still use ${OBSERVABILITY_STORAGE_ROOT}/checkmk but may live on root disk."
fi

kubectl get ns "$NAMESPACE" >/dev/null 2>&1 || kubectl create ns "$NAMESPACE" >/dev/null
rand(){ openssl rand -base64 32 | tr -d '\n'; }
if kubectl -n "$NAMESPACE" get secret checkmk-admin >/dev/null 2>&1; then
  log "Preserving existing checkmk-admin secret"
else
  CHECKMK_ADMIN_PASSWORD="${CHECKMK_ADMIN_PASSWORD:-$(rand)}"
  log "Creating checkmk-admin secret for cmkadmin"
  kubectl -n "$NAMESPACE" create secret generic checkmk-admin \
    --from-literal=CMK_PASSWORD="$CHECKMK_ADMIN_PASSWORD" >/dev/null
fi
if kubectl -n "$NAMESPACE" get secret checkmk-sso >/dev/null 2>&1; then
  log "Preserving existing checkmk-sso secret"
else
  log "Creating checkmk-sso contract secret"
  kubectl -n "$NAMESPACE" create secret generic checkmk-sso \
    --from-literal=CHECKMK_SITE="$CHECKMK_SITE" \
    --from-literal=CHECKMK_REMOTE_USER_HEADER="$CHECKMK_REMOTE_USER_HEADER" \
    --from-literal=CHECKMK_PUBLIC_URL="https://checkmk.${BASE_DOMAIN}/${CHECKMK_SITE}/" >/dev/null
fi
log "Checkmk operations prerequisites reconciled"
kubectl -n "$NAMESPACE" get secret checkmk-admin checkmk-sso >/dev/null
