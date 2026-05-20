#!/usr/bin/env bash
set -euo pipefail
CM_NS="${CM_NS:-cert-manager}"
: "${CF_API_TOKEN:?CF_API_TOKEN is required}"
log(){ echo "[CH03][cloudflare-secret][$(date -u +%FT%TZ)] $*"; }
log "Applying Cloudflare API token secret in namespace ${CM_NS}"
kubectl -n "$CM_NS" create secret generic cloudflare-api-token-secret \
  --from-literal=api-token="$CF_API_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
log "Secret synced"
