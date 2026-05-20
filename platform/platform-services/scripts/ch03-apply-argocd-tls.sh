#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_ISSUER="${CLUSTER_ISSUER:-letsencrypt-staging}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
TMP_DIR="$(mktemp -d)"
cleanup(){ rm -rf "$TMP_DIR"; }
trap cleanup EXIT
sed -e "s|__CLUSTER_ISSUER__|${CLUSTER_ISSUER}|g" -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" "$ROOT_DIR/ingress/argocd-certificate.yaml" > "$TMP_DIR/argocd-certificate.yaml"
sed -e "s|__BASE_DOMAIN__|${BASE_DOMAIN}|g" "$ROOT_DIR/ingress/argocd-ingress.yaml" > "$TMP_DIR/argocd-ingress.yaml"
kubectl apply -f "$TMP_DIR/argocd-ingress.yaml"
kubectl apply -f "$TMP_DIR/argocd-certificate.yaml"
