#!/usr/bin/env bash
set -euo pipefail

############################################
# CH04 - Argo CD bootstrap and self-management validation
#
# Validates:
#   - argocd namespace and control plane workloads are available
#   - argocd-server runs in ingress mode (server.insecure=true)
#   - AppProject platform-services exists
#   - ApplicationSet platform-services exists
#   - Application argocd-self is Synced (Argo CD owns its own manifests)
#   - ApplicationSet generated the platform service Applications
#
# Read-only: never mutates cluster state. Aggregates all findings before
# exiting non-zero.
############################################

log()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04-argocd] $*"; }
warn() { echo "[$(date -u +%FT%TZ)] [VAL][CH04-argocd][WARN] $*" >&2; }
die()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04-argocd][FAIL] $*" >&2; exit 1; }

ARGOCD_NS="${ARGOCD_NS:-argocd}"
APPSET_NAME="${APPSET_NAME:-platform-services}"
SELF_APP_NAME="${SELF_APP_NAME:-argocd-self}"
ARGOCD_APP_WAIT="${ARGOCD_APP_WAIT:-60}"

PASS=0
FAIL=0
pass() { log "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "[$(date -u +%FT%TZ)] [VAL][CH04-argocd][FAIL] $*" >&2; FAIL=$((FAIL + 1)); }

wait_for_application() {
  local name="$1" deadline=$((SECONDS + ARGOCD_APP_WAIT))
  while ((SECONDS < deadline)); do
    if kubectl -n "${ARGOCD_NS}" get application "${name}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

log "=== CH04 Argo CD bootstrap validation ==="

command -v kubectl >/dev/null 2>&1 || die "kubectl not available"

if ! kubectl get nodes >/dev/null 2>&1; then
  die "kubectl cannot reach the cluster (check KUBECONFIG)"
fi

# 1. Namespace
if kubectl get namespace "${ARGOCD_NS}" >/dev/null 2>&1; then
  pass "namespace ${ARGOCD_NS} exists"
else
  fail "namespace ${ARGOCD_NS} not found (run bootstrap-argocd.sh)"
fi

# 2. Control plane workloads
for dep in argocd-server argocd-repo-server argocd-applicationset-controller; do
  if kubectl -n "${ARGOCD_NS}" get deploy "${dep}" >/dev/null 2>&1; then
    if kubectl -n "${ARGOCD_NS}" rollout status "deploy/${dep}" --timeout=60s >/dev/null 2>&1; then
      pass "deployment ${ARGOCD_NS}/${dep} available"
    else
      fail "deployment ${ARGOCD_NS}/${dep} not available"
    fi
  else
    fail "deployment ${ARGOCD_NS}/${dep} not found"
  fi
done

if kubectl -n "${ARGOCD_NS}" get statefulset argocd-application-controller >/dev/null 2>&1; then
  if kubectl -n "${ARGOCD_NS}" rollout status statefulset/argocd-application-controller --timeout=60s >/dev/null 2>&1; then
    pass "statefulset ${ARGOCD_NS}/argocd-application-controller available"
  else
    fail "statefulset ${ARGOCD_NS}/argocd-application-controller not available"
  fi
else
  fail "statefulset ${ARGOCD_NS}/argocd-application-controller not found"
fi

# 3. Ingress mode
SERVER_INSECURE="$(kubectl -n "${ARGOCD_NS}" get configmap argocd-cmd-params-cm \
  -o jsonpath='{.data.server\.insecure}' 2>/dev/null || true)"
if [[ "${SERVER_INSECURE}" == "true" ]]; then
  pass "argocd-server ingress mode enabled (server.insecure=true)"
else
  fail "server.insecure='${SERVER_INSECURE}' (expected true)"
fi

# 4. AppProject
if kubectl -n "${ARGOCD_NS}" get appproject platform-services >/dev/null 2>&1; then
  pass "AppProject platform-services exists"
else
  fail "AppProject platform-services not found (argocd-self must reconcile it)"
fi

# 5. ApplicationSet
if kubectl -n "${ARGOCD_NS}" get applicationset "${APPSET_NAME}" >/dev/null 2>&1; then
  pass "ApplicationSet ${APPSET_NAME} exists"
  if kubectl -n "${ARGOCD_NS}" get applicationset "${APPSET_NAME}" \
    -o jsonpath='{.spec.template.spec.syncPolicy.automated}' 2>/dev/null | grep -q '.'; then
    pass "ApplicationSet ${APPSET_NAME} uses automated sync"
  else
    fail "ApplicationSet ${APPSET_NAME} has no automated sync policy"
  fi
else
  fail "ApplicationSet ${APPSET_NAME} not found"
fi

# 6. Self-management Application
if kubectl -n "${ARGOCD_NS}" get application "${SELF_APP_NAME}" >/dev/null 2>&1; then
  SELF_SYNC="$(kubectl -n "${ARGOCD_NS}" get application "${SELF_APP_NAME}" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || true)"
  SELF_HEALTH="$(kubectl -n "${ARGOCD_NS}" get application "${SELF_APP_NAME}" \
    -o jsonpath='{.status.health.status}' 2>/dev/null || true)"
  if [[ "${SELF_SYNC}" == "Synced" ]]; then
    pass "Application ${SELF_APP_NAME} is Synced (health: ${SELF_HEALTH:-unknown})"
  else
    fail "Application ${SELF_APP_NAME} sync status '${SELF_SYNC:-unknown}' (expected Synced)"
  fi
else
  fail "Application ${SELF_APP_NAME} not found"
fi

# 7. Generated platform service Applications
for app in platform-traefik-exposure platform-cert-manager-issuers; do
  if wait_for_application "${app}"; then
    pass "generated Application ${app} exists"
  else
    fail "generated Application ${app} not found after ${ARGOCD_APP_WAIT}s (check the ApplicationSet controller)"
  fi
done

log "=== Summary: PASS=${PASS} FAIL=${FAIL} ==="

if [[ ${FAIL} -gt 0 ]]; then
  die "${FAIL} check(s) failed"
fi

log "CH04 Argo CD bootstrap contract satisfied"
