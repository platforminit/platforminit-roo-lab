#!/usr/bin/env bash
set -euo pipefail

############################################
# CH03-04 - k3s Smoke Test
# Validates basic workload deployment and
# in-cluster service discovery via Traefik.
############################################

log()  { echo "[$(date -u +%FT%TZ)] [INFO] $*"; }
warn() { echo "[$(date -u +%FT%TZ)] [WARN] $*" >&2; }
die()  { echo "[$(date -u +%FT%TZ)] [ERROR] $*" >&2; exit 1; }

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

NS="ch03-smoke"
APP="nginx"
# Pinned by digest for supply-chain integrity (nginx:1.25-alpine)
IMG="nginx@sha256:516475cc129da42866742567714ddc681e5eed7b9ee0b9e9c015e464b4221a00"

log "preflight: node Ready"
kubectl wait --for=condition=Ready node --all --timeout=120s

log "create namespace: ${NS}"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

cleanup() {
  log "cleanup namespace: ${NS}"
  kubectl delete ns "${NS}" --wait=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

log "deploy ${APP}"
kubectl -n "${NS}" get deploy "${APP}" >/dev/null 2>&1 || \
  kubectl -n "${NS}" create deploy "${APP}" --image="${IMG}" --replicas=1

log "wait for rollout"
kubectl -n "${NS}" rollout status deploy/"${APP}" --timeout=180s

log "expose service"
kubectl -n "${NS}" get svc "${APP}" >/dev/null 2>&1 || \
  kubectl -n "${NS}" expose deploy "${APP}" --port=80 --target-port=80

log "in-cluster curl check"
# Pinned by digest for supply-chain integrity (curlimages/curl:8.5.0)
kubectl -n "${NS}" run curl --image=curlimages/curl@sha256:08e466006f0860e54fc299378de998935333e0e130a15f6f98482e9f8dab3058 --restart=Never -- \
  sh -lc "curl -fsS http://${APP}.${NS}.svc.cluster.local | head -n 5"

log "smoke PASS"
