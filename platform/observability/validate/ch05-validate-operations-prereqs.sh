#!/usr/bin/env bash
set -euo pipefail
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
export KUBECONFIG
kubectl -n "$NAMESPACE" get secret checkmk-admin checkmk-sso >/dev/null
echo "PASS: Checkmk operations prerequisite secrets exist"
