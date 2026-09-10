#!/usr/bin/env bash
set -euo pipefail

############################################
# CH04 - Traefik LoadBalancer exposure validation
#
# Validates:
#   - k3s HelmChartConfig for Traefik is applied and declares a
#     LoadBalancer service exposing ports 80/443
#   - kube-system/traefik Service is type LoadBalancer with ports 80/443
#   - ServiceLB (svclb) workload exists and a LoadBalancer IP or hostname is
#     bound after a bounded wait (a pending LoadBalancer fails the run)
#   - Traefik pods are running and the traefik IngressClass exists
#
# Read-only: never mutates cluster state. Aggregates all findings before
# exiting non-zero, so a single run shows the full picture.
#
# Inputs:
#   LB_WAIT_TIMEOUT  LoadBalancer endpoint wait in seconds (default: 60,
#                    allowed range 15-900); validated before cluster access
############################################

log()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04-traefik] $*"; }
warn() { echo "[$(date -u +%FT%TZ)] [VAL][CH04-traefik][WARN] $*" >&2; }
die()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04-traefik][FAIL] $*" >&2; exit 1; }

LB_WAIT_TIMEOUT="${LB_WAIT_TIMEOUT:-60}"
LB_WAIT_TIMEOUT_MIN=15
LB_WAIT_TIMEOUT_MAX=900

PASS=0
FAIL=0
pass() { log "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "[$(date -u +%FT%TZ)] [VAL][CH04-traefik][FAIL] $*" >&2; FAIL=$((FAIL + 1)); }

log "=== CH04 Traefik LoadBalancer exposure validation ==="

command -v kubectl >/dev/null 2>&1 || die "kubectl not available"

# Input validation: keep malformed or unbounded waits away from the cluster.
[[ "${LB_WAIT_TIMEOUT}" =~ ^[0-9]+$ ]] || die "LB_WAIT_TIMEOUT must be an integer number of seconds (got '${LB_WAIT_TIMEOUT}')."
(( LB_WAIT_TIMEOUT >= LB_WAIT_TIMEOUT_MIN )) || die "LB_WAIT_TIMEOUT=${LB_WAIT_TIMEOUT}s is below the minimum ${LB_WAIT_TIMEOUT_MIN}s; a shorter wait would report a backgrounding ServiceLB as a failure."
(( LB_WAIT_TIMEOUT <= LB_WAIT_TIMEOUT_MAX )) || die "LB_WAIT_TIMEOUT=${LB_WAIT_TIMEOUT}s exceeds the maximum ${LB_WAIT_TIMEOUT_MAX}s; the endpoint wait must stay operator-bounded."

if ! kubectl get nodes >/dev/null 2>&1; then
  die "kubectl cannot reach the cluster (check KUBECONFIG)"
fi

# 1. HelmChartConfig present
if kubectl -n kube-system get helmchartconfig traefik >/dev/null 2>&1; then
  pass "HelmChartConfig kube-system/traefik exists"

  HCC_VALUES="$(kubectl -n kube-system get helmchartconfig traefik \
    -o jsonpath='{.spec.valuesContent}' 2>/dev/null || true)"

  if grep -Eq '^[[:space:]]*type:[[:space:]]*LoadBalancer[[:space:]]*$' <<<"${HCC_VALUES}"; then
    pass "HelmChartConfig declares service type LoadBalancer"
  else
    fail "HelmChartConfig does not declare service type LoadBalancer"
  fi

  if grep -Eq '^[[:space:]]*exposedPort:[[:space:]]*80[[:space:]]*$' <<<"${HCC_VALUES}" \
    && grep -Eq '^[[:space:]]*exposedPort:[[:space:]]*443[[:space:]]*$' <<<"${HCC_VALUES}"; then
    pass "HelmChartConfig exposes ports 80 and 443"
  else
    fail "HelmChartConfig does not expose ports 80 and 443"
  fi
else
  fail "HelmChartConfig kube-system/traefik not found (Traefik exposure is contract-required)"
fi

# 2. Traefik Service
if kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
  pass "Service kube-system/traefik exists"

  SVC_TYPE="$(kubectl -n kube-system get svc traefik -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  if [[ "${SVC_TYPE}" == "LoadBalancer" ]]; then
    pass "Service type is LoadBalancer"
  else
    fail "Service type is '${SVC_TYPE}' (expected LoadBalancer)"
  fi

  SVC_PORTS="$(kubectl -n kube-system get svc traefik \
    -o jsonpath='{range .spec.ports[*]}{.port}{" "}{end}' 2>/dev/null || true)"
  if [[ " ${SVC_PORTS} " == *" 80 "* && " ${SVC_PORTS} " == *" 443 "* ]]; then
    pass "Service exposes ports 80 and 443"
  else
    fail "Service ports: '${SVC_PORTS}' (expected 80 and 443)"
  fi

  # A pending LoadBalancer is a contract failure, not a warning: the acceptance
  # criterion is service exposure on 80/443. Accept either the ip or the
  # hostname form of the endpoint, but require one of them after a bounded wait.
  LB_ENDPOINT=""
  LB_DEADLINE=$((SECONDS + LB_WAIT_TIMEOUT))
  while ((SECONDS < LB_DEADLINE)); do
    LB_ENDPOINT="$(kubectl -n kube-system get svc traefik \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -z "${LB_ENDPOINT}" ]]; then
      LB_ENDPOINT="$(kubectl -n kube-system get svc traefik \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    fi
    if [[ -n "${LB_ENDPOINT}" ]]; then
      break
    fi
    sleep 5
  done

  if [[ -n "${LB_ENDPOINT}" ]]; then
    pass "LoadBalancer endpoint bound (ip or hostname): ${LB_ENDPOINT}"
  else
    fail "LoadBalancer endpoint (status.loadBalancer.ingress[].ip or .hostname) not bound after ${LB_WAIT_TIMEOUT}s (ServiceLB pending)"
  fi
else
  fail "Service kube-system/traefik not found"
fi

# 3. ServiceLB workload
if kubectl -n kube-system get daemonset -o name 2>/dev/null | grep -Eq 'svclb-traefik'; then
  pass "ServiceLB daemonset (svclb-traefik) present"
else
  fail "ServiceLB daemonset (svclb-traefik) not found"
fi

# 4. Traefik pods
TRAEFIK_READY="$(kubectl -n kube-system get pods -l app.kubernetes.io/name=traefik \
  -o jsonpath='{range .items[*]}{.status.phase}{" "}{end}' 2>/dev/null || true)"
if [[ -n "${TRAEFIK_READY}" ]]; then
  if grep -q "Running" <<<"${TRAEFIK_READY}"; then
    pass "Traefik pod(s) running"
  else
    fail "Traefik pod states: '${TRAEFIK_READY}' (expected Running)"
  fi
else
  fail "No Traefik pods found in kube-system"
fi

# 5. IngressClass
if kubectl get ingressclass traefik >/dev/null 2>&1; then
  pass "IngressClass traefik exists"
else
  fail "IngressClass traefik not found"
fi

log "=== Summary: PASS=${PASS} FAIL=${FAIL} ==="

if [[ ${FAIL} -gt 0 ]]; then
  die "${FAIL} check(s) failed"
fi

log "CH04 Traefik exposure contract satisfied"
