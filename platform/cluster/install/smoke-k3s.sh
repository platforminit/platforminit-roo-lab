#!/usr/bin/env bash
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

NS="ch02-smoke"
APP="nginx"
IMG="nginx:1.25-alpine"

echo "[INFO] preflight: node Ready"
kubectl wait --for=condition=Ready node --all --timeout=120s

echo "[INFO] create namespace: ${NS}"
kubectl get ns "${NS}" >/dev/null 2>&1 || kubectl create ns "${NS}"

cleanup() {
  echo "[INFO] cleanup namespace: ${NS}"
  kubectl delete ns "${NS}" --wait=true >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[INFO] deploy ${APP}"
kubectl -n "${NS}" get deploy "${APP}" >/dev/null 2>&1 || \
  kubectl -n "${NS}" create deploy "${APP}" --image="${IMG}" --replicas=1

echo "[INFO] wait for rollout"
kubectl -n "${NS}" rollout status deploy/"${APP}" --timeout=180s

echo "[INFO] expose service"
kubectl -n "${NS}" get svc "${APP}" >/dev/null 2>&1 || \
  kubectl -n "${NS}" expose deploy "${APP}" --port=80 --target-port=80

echo "[INFO] in-cluster curl check"
kubectl -n "${NS}" run curl --image=curlimages/curl:8.5.0 --restart=Never -- \
  sh -lc "curl -fsS http://${APP}.${NS}.svc.cluster.local | head -n 5"

echo "[SUCCESS] smoke PASS"
