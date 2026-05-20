#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_MODE="${DEPLOY_MODE:-staging}"
PUBLIC_IP="${PUBLIC_IP:-}"
log(){ echo "[CH03][$(date -u +%FT%TZ)] $*"; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: missing binary: $1" >&2; exit 1; }; }
need kubectl
need openssl
need curl
: "${CF_API_TOKEN:?CF_API_TOKEN is required}"
: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL is required}"
ISSUER_SET="both"
CLUSTER_ISSUER="letsencrypt-staging"
EXPECTED_ISSUER_REGEX="Fake LE Intermediate|Let's Encrypt"
if [[ "$DEPLOY_MODE" == "prod" ]]; then
  CLUSTER_ISSUER="letsencrypt-prod"
  EXPECTED_ISSUER_REGEX="Let's Encrypt"
fi
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
log "Install cert-manager"
bash "$ROOT_DIR/cert-manager/install-cert-manager.sh"
log "Sync Cloudflare secret"
bash "$ROOT_DIR/scripts/ch03-sync-cloudflare-secret.sh"
log "Apply issuers"
ISSUER_SET="$ISSUER_SET" LETSENCRYPT_EMAIL="$LETSENCRYPT_EMAIL" bash "$ROOT_DIR/scripts/ch03-apply-issuers.sh"
log "Wait for ClusterIssuer ${CLUSTER_ISSUER} Ready"
kubectl wait --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True clusterissuer/${CLUSTER_ISSUER} --timeout=300s || true
log "Ensure Argo CD baseline is recoverable before TLS/SSO layers"
BASE_DOMAIN="$BASE_DOMAIN" bash "$ROOT_DIR/scripts/ch03-ensure-argocd-baseline.sh"
log "Apply Argo CD TLS manifests using issuer ${CLUSTER_ISSUER}"
CLUSTER_ISSUER="$CLUSTER_ISSUER" bash "$ROOT_DIR/scripts/ch03-apply-argocd-tls.sh"
log "Validate"
bash "$ROOT_DIR/validate/validate-cert-manager.sh"
log "Smoke TLS"
ARGOCD_HOSTNAME="argocd.${BASE_DOMAIN}" EXPECTED_ISSUER_REGEX="$EXPECTED_ISSUER_REGEX" PUBLIC_IP="$PUBLIC_IP" bash "$ROOT_DIR/validate/smoke-argocd-tls.sh"
log "CH03 completed"
