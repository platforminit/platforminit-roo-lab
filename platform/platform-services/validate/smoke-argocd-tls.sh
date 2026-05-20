#!/usr/bin/env bash
set -euo pipefail

HOSTNAME="${ARGOCD_HOSTNAME:-argocd.sysadminhomelab.hu}"
EXPECTED_ISSUER_REGEX="${EXPECTED_ISSUER_REGEX:-Lets Encrypt|Fake LE Intermediate}"
PUBLIC_IP="${PUBLIC_IP:-}"

log(){ echo "[CH03][smoke][$(date -u +%FT%TZ)] $*"; }

wait_for_cert_ready(){
  kubectl -n argocd wait --for=condition=Ready certificate/argocd-tls --timeout=600s
}

fetch_cert(){
  local target
  if [[ -n "$PUBLIC_IP" ]]; then
    target="$PUBLIC_IP:443"
  else
    target="$HOSTNAME:443"
  fi
  echo | openssl s_client -servername "$HOSTNAME" -connect "$target" 2>/dev/null | openssl x509 -noout -issuer -subject -dates
}

wait_for_cert_ready
OUT="$(fetch_cert)"
log "$OUT"

printf '%s\n' "$OUT" | grep -Eiq "Let's Encrypt|Lets Encrypt|Fake LE Intermediate" || {
  echo "FATAL: expected issuer not found in certificate output" >&2
  exit 1
}

log "TLS smoke PASS"