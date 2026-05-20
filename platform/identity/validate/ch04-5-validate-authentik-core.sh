#!/usr/bin/env bash
set -euo pipefail

ns="${NAMESPACE:-identity}"
base_domain="${BASE_DOMAIN:-sysadminhomelab.hu}"

pass() { echo "PASS | $1 | $2"; }
fail() { echo "FAIL | $1 | $2"; exit 1; }
warn() { echo "WARN | $1 | $2"; }

kubectl get ns "$ns" >/dev/null 2>&1 && pass "NAMESPACE" "${ns} namespace exists" || fail "NAMESPACE" "missing ${ns} namespace"

kubectl -n "$ns" get secret authentik-core >/dev/null 2>&1 && pass "CORE_SECRET" "authentik core secret exists" || fail "CORE_SECRET" "missing authentik-core secret"
kubectl -n "$ns" get secret authentik-postgresql-credentials >/dev/null 2>&1 && pass "POSTGRES_SECRET" "postgresql credentials secret exists" || fail "POSTGRES_SECRET" "missing authentik-postgresql-credentials secret"
kubectl -n "$ns" get secret authentik-bootstrap >/dev/null 2>&1 && pass "BOOTSTRAP_SECRET" "bootstrap secret exists" || fail "BOOTSTRAP_SECRET" "missing authentik-bootstrap secret"

kubectl -n "$ns" get deploy authentik-server >/dev/null 2>&1 && pass "SERVER_DEPLOYMENT" "authentik-server deployment exists" || fail "SERVER_DEPLOYMENT" "missing authentik-server deployment"
kubectl -n "$ns" get deploy authentik-worker >/dev/null 2>&1 && pass "WORKER_DEPLOYMENT" "authentik-worker deployment exists" || fail "WORKER_DEPLOYMENT" "missing authentik-worker deployment"
kubectl -n "$ns" rollout status deploy/authentik-server --timeout=10s >/dev/null 2>&1 && pass "SERVER_ROLLOUT" "authentik-server rollout is healthy" || fail "SERVER_ROLLOUT" "authentik-server rollout not healthy"
kubectl -n "$ns" rollout status deploy/authentik-worker --timeout=10s >/dev/null 2>&1 && pass "WORKER_ROLLOUT" "authentik-worker rollout is healthy" || fail "WORKER_ROLLOUT" "authentik-worker rollout not healthy"

kubectl -n "$ns" get svc authentik-server >/dev/null 2>&1 && pass "SERVER_SERVICE" "authentik-server service exists" || fail "SERVER_SERVICE" "missing authentik-server service"
kubectl -n "$ns" get ingress authentik >/dev/null 2>&1 && pass "INGRESS" "authentik ingress exists" || fail "INGRESS" "missing authentik ingress"
kubectl -n "$ns" get certificate authentik-tls >/dev/null 2>&1 && pass "CERTIFICATE" "authentik certificate exists" || fail "CERTIFICATE" "missing authentik certificate"

host="auth.${base_domain}"
actual_host="$(kubectl -n "$ns" get ingress authentik -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || true)"
[[ "$actual_host" == "$host" ]] && pass "INGRESS_HOST" "ingress host is ${host}" || fail "INGRESS_HOST" "expected ${host}, got ${actual_host:-empty}"

ready_pods="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | awk '$2 ~ /^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if (a[1]==a[2]) c++} END {print c+0}')"
if [[ "${ready_pods}" -ge 2 ]]; then
  pass "PODS_READY" "${ready_pods} pods report all containers ready"
else
  fail "PODS_READY" "expected at least 2 ready pods, got ${ready_pods}"
fi

cert_ready="$(kubectl -n "$ns" get certificate authentik-tls -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || true)"
if [[ "$cert_ready" == "True" ]]; then
  pass "TLS_READY" "authentik certificate is Ready"
else
  warn "TLS_READY" "certificate not Ready yet; DNS/ACME may still be converging"
fi
