#!/usr/bin/env bash
set -euo pipefail

############################################
# CH04 - cert-manager + Cloudflare DNS-01 validation
#
# Validates:
#   - cert-manager CRDs and control plane workloads are available
#   - ClusterIssuers letsencrypt-staging / letsencrypt-prod exist
#   - each issuer uses the dns01 Cloudflare solver
#   - the Cloudflare API token secret exists with the expected key
#     (secret values are never printed)
#
# Read-only: never mutates cluster state. Aggregates all findings before
# exiting non-zero.
############################################

log()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04-cert-manager] $*"; }
warn() { echo "[$(date -u +%FT%TZ)] [VAL][CH04-cert-manager][WARN] $*" >&2; }
die()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04-cert-manager][FAIL] $*" >&2; exit 1; }

CM_NS="${CM_NS:-cert-manager}"
CF_SECRET_NAME="${CF_SECRET_NAME:-cloudflare-api-token-secret}"
CF_SECRET_KEY="${CF_SECRET_KEY:-api-token}"

PASS=0
FAIL=0
pass() { log "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "[$(date -u +%FT%TZ)] [VAL][CH04-cert-manager][FAIL] $*" >&2; FAIL=$((FAIL + 1)); }

log "=== CH04 cert-manager DNS-01 validation ==="

command -v kubectl >/dev/null 2>&1 || die "kubectl not available"

if ! kubectl get nodes >/dev/null 2>&1; then
  die "kubectl cannot reach the cluster (check KUBECONFIG)"
fi

# 1. CRDs
for crd in clusterissuers.cert-manager.io certificates.cert-manager.io; do
  if kubectl get crd "${crd}" >/dev/null 2>&1; then
    pass "CRD ${crd} installed"
  else
    fail "CRD ${crd} missing"
  fi
done

# 2. Control plane workloads
for dep in cert-manager cert-manager-webhook cert-manager-cainjector; do
  if kubectl -n "${CM_NS}" get deploy "${dep}" >/dev/null 2>&1; then
    if kubectl -n "${CM_NS}" rollout status "deploy/${dep}" --timeout=60s >/dev/null 2>&1; then
      pass "deployment ${CM_NS}/${dep} available"
    else
      fail "deployment ${CM_NS}/${dep} not available"
    fi
  else
    fail "deployment ${CM_NS}/${dep} not found"
  fi
done

# 3. ClusterIssuers + solver wiring
for issuer in letsencrypt-staging letsencrypt-prod; do
  if kubectl get clusterissuer "${issuer}" >/dev/null 2>&1; then
    pass "ClusterIssuer ${issuer} exists"

    ISSUER_JSON="$(kubectl get clusterissuer "${issuer}" -o json 2>/dev/null || true)"

    if grep -q '"dns01"' <<<"${ISSUER_JSON}"; then
      pass "ClusterIssuer ${issuer} uses a dns01 solver"
    else
      fail "ClusterIssuer ${issuer} does not use a dns01 solver"
    fi

    if grep -q '"cloudflare"' <<<"${ISSUER_JSON}"; then
      pass "ClusterIssuer ${issuer} uses the Cloudflare DNS-01 provider"
    else
      fail "ClusterIssuer ${issuer} does not use the Cloudflare provider"
    fi

    ISSUER_SECRET="$(kubectl get clusterissuer "${issuer}" \
      -o jsonpath='{.spec.acme.solvers[0].dns01.cloudflare.apiTokenSecretRef.name}' 2>/dev/null || true)"
    if [[ "${ISSUER_SECRET}" == "${CF_SECRET_NAME}" ]]; then
      pass "ClusterIssuer ${issuer} references secret ${CF_SECRET_NAME}"
    else
      fail "ClusterIssuer ${issuer} references secret '${ISSUER_SECRET}' (expected ${CF_SECRET_NAME})"
    fi
  else
    fail "ClusterIssuer ${issuer} not found (expected Argo CD to reconcile it)"
  fi
done

# 4. Cloudflare API token secret (existence only)
if kubectl -n "${CM_NS}" get secret "${CF_SECRET_NAME}" >/dev/null 2>&1; then
  pass "Secret ${CM_NS}/${CF_SECRET_NAME} exists"

  KEY_VALUE="$(kubectl -n "${CM_NS}" get secret "${CF_SECRET_NAME}" \
    -o jsonpath="{.data.${CF_SECRET_KEY}}" 2>/dev/null || true)"
  if [[ -n "${KEY_VALUE}" ]]; then
    pass "Secret key '${CF_SECRET_KEY}' present (value not printed)"
  else
    fail "Secret key '${CF_SECRET_KEY}' missing in ${CM_NS}/${CF_SECRET_NAME}"
  fi
else
  fail "Secret ${CM_NS}/${CF_SECRET_NAME} not found (DNS-01 issuance will fail)"
fi

log "=== Summary: PASS=${PASS} FAIL=${FAIL} ==="

if [[ ${FAIL} -gt 0 ]]; then
  die "${FAIL} check(s) failed"
fi

log "CH04 cert-manager DNS-01 contract satisfied"
