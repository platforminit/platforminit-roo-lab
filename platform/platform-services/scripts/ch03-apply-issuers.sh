#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${LETSENCRYPT_EMAIL:?LETSENCRYPT_EMAIL is required}"
ISSUER_SET="${ISSUER_SET:-both}"
TMP_DIR="$(mktemp -d)"
cleanup(){ rm -rf "$TMP_DIR"; }
trap cleanup EXIT
render(){
  local src="$1" dst="$2"
  sed "s|__LETSENCRYPT_EMAIL__|${LETSENCRYPT_EMAIL}|g" "$src" > "$dst"
}
case "$ISSUER_SET" in
  staging)
    render "$ROOT_DIR/issuers/clusterissuer-letsencrypt-staging.yaml" "$TMP_DIR/staging.yaml"
    kubectl apply -f "$TMP_DIR/staging.yaml"
    ;;
  prod)
    render "$ROOT_DIR/issuers/clusterissuer-letsencrypt-prod.yaml" "$TMP_DIR/prod.yaml"
    kubectl apply -f "$TMP_DIR/prod.yaml"
    ;;
  both)
    render "$ROOT_DIR/issuers/clusterissuer-letsencrypt-staging.yaml" "$TMP_DIR/staging.yaml"
    render "$ROOT_DIR/issuers/clusterissuer-letsencrypt-prod.yaml" "$TMP_DIR/prod.yaml"
    kubectl apply -f "$TMP_DIR/staging.yaml"
    kubectl apply -f "$TMP_DIR/prod.yaml"
    ;;
  *)
    echo "FATAL: invalid ISSUER_SET=$ISSUER_SET" >&2
    exit 1
    ;;
esac
