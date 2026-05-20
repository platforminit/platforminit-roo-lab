#!/usr/bin/env bash
set -euo pipefail
CM_VERSION="${CM_VERSION:-v1.14.4}"
CM_NS="${CM_NS:-cert-manager}"
log(){ echo "[CH03][cert-manager][$(date -u +%FT%TZ)] $*"; }
need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: missing binary: $1" >&2; exit 1; }; }
need kubectl
need curl
log "Ensuring namespace ${CM_NS}"
kubectl get ns "$CM_NS" >/dev/null 2>&1 || kubectl create namespace "$CM_NS"
URL="https://github.com/cert-manager/cert-manager/releases/download/${CM_VERSION}/cert-manager.yaml"
log "Applying cert-manager ${CM_VERSION} from ${URL}"
kubectl apply -f "$URL"
log "Waiting for deployments"
kubectl -n "$CM_NS" rollout status deploy/cert-manager --timeout=300s
kubectl -n "$CM_NS" rollout status deploy/cert-manager-cainjector --timeout=300s
kubectl -n "$CM_NS" rollout status deploy/cert-manager-webhook --timeout=300s
log "cert-manager ready"
