#!/usr/bin/env bash
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG
kubectl -n argocd get appproject.argoproj.io operations >/dev/null
kubectl -n argocd get application.argoproj.io operations-stack >/dev/null
echo "PASS: operations-stack Argo CD registration exists"
