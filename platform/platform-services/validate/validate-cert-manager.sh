#!/usr/bin/env bash
set -euo pipefail
CM_NS="${CM_NS:-cert-manager}"
log(){ echo "[CH03][validate][$(date -u +%FT%TZ)] $*"; }
log "Checking cert-manager deployments"
kubectl -n "$CM_NS" get deploy cert-manager cert-manager-cainjector cert-manager-webhook
log "Checking issuers"
kubectl get clusterissuers
log "Checking argocd certificate"
kubectl -n argocd get certificate argocd-tls
log "Checking argocd ingress"
kubectl -n argocd get ingress argocd
