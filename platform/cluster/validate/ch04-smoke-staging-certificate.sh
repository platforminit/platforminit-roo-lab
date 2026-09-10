#!/usr/bin/env bash
set -euo pipefail

############################################
# CH04 - Let's Encrypt STAGING certificate issuance smoke check
#
# Proves the complete cert-manager DNS-01 loop (Cloudflare API + ACME staging)
# by requesting one staging Certificate and waiting, bounded, for Ready=True.
#
# This is the only CH04 validator that creates cluster resources, therefore it is:
#   - opt-in:      requires PLATFORMINIT_ALLOW_STAGING_CERT_SMOKE=true
#   - staging:     refuses any issuer other than letsencrypt-staging
#   - run-owned:   every object it creates carries a unique run id, and any
#                  collision with a pre-existing object is refused, never adopted
#   - bounded:     SMOKE_TIMEOUT (default 300s, allowed range 30-1800s)
#   - self-clean:  the Certificate, the TLS Secret and the run namespace are
#                  removed on exit, on success and on failure, with no
#                  keep-resources bypass that could strand resources
#
# Inputs:
#   SMOKE_NAMESPACE_PREFIX  namespace prefix (default: cert-manager-smoke)
#   SMOKE_RUN_ID            run identity suffix (default: UTC timestamp + PID)
#   SMOKE_TIMEOUT           wait budget in seconds (default: 300)
#
# Secret safety: only status conditions/state fields are printed. Secret data,
# API tokens, ACME account keys and full resource dumps are never emitted.
#
# Usage:
#   sudo PLATFORMINIT_ALLOW_STAGING_CERT_SMOKE=true \
#     bash platform/cluster/validate/ch04-smoke-staging-certificate.sh
############################################

log()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04-cert-smoke] $*"; }
warn() { echo "[$(date -u +%FT%TZ)] [VAL][CH04-cert-smoke][WARN] $*" >&2; }
die()  { echo "[$(date -u +%FT%TZ)] [VAL][CH04-cert-smoke][FAIL] $*" >&2; exit 1; }

SMOKE_NAMESPACE_PREFIX="${SMOKE_NAMESPACE_PREFIX:-cert-manager-smoke}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-300}"
SMOKE_TIMEOUT_MIN=30
SMOKE_TIMEOUT_MAX=1800
SMOKE_ISSUER="letsencrypt-staging"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SMOKE_MANIFEST="${SCRIPT_DIR}/../addons/cert-manager/smoke/demo-cert-smoke.yaml"
SMOKE_NAMESPACE_COMMITTED="cert-manager-smoke"
CERT_NAME_COMMITTED="demo-sysadminhomelab-tls"
CERT_SECRET_COMMITTED="demo-tls"
SMOKE_RUN_LABEL="platforminit.io/smoke-run"

# Lowercase, DNS-1123-safe and length-bounded run identity, so the derived
# namespace/object names stay inside the 63-character label limit.
sanitize_run_id() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -c 'a-z0-9-' '-' \
    | sed -E 's/-+/-/g; s/^-+//; s/-+$//' \
    | cut -c1-24
}

RUN_ID="$(sanitize_run_id "${SMOKE_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}")"
SMOKE_NAMESPACE="${SMOKE_NAMESPACE_PREFIX}-${RUN_ID}"
CERT_NAME="${CERT_NAME_COMMITTED}-${RUN_ID}"
CERT_SECRET="${CERT_SECRET_COMMITTED}-${RUN_ID}"

RUN_STARTED=false
NAMESPACE_CREATED=false

PASS=0
FAIL=0
pass() { log "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "[$(date -u +%FT%TZ)] [VAL][CH04-cert-smoke][FAIL] $*" >&2; FAIL=$((FAIL + 1)); }

# Unconditional cleanup. There is deliberately no keep-resources bypass: the
# accepted procedure must never leave resources behind, and cleanup only ever
# touches objects that carry this run's unique identity.
cleanup() {
  local exit_code=$?

  trap - EXIT

  if [[ "${RUN_STARTED}" != "true" ]]; then
    return "${exit_code}"
  fi

  log "Cleanup: removing run-owned resources (run id ${RUN_ID}, namespace ${SMOKE_NAMESPACE})."

  if ! kubectl -n "${SMOKE_NAMESPACE}" delete certificate "${CERT_NAME}" \
    --ignore-not-found --wait=false >/dev/null 2>&1; then
    warn "Cleanup: certificate ${SMOKE_NAMESPACE}/${CERT_NAME} could not be deleted; remove it manually."
  fi

  if ! kubectl -n "${SMOKE_NAMESPACE}" delete secret "${CERT_SECRET}" \
    --ignore-not-found >/dev/null 2>&1; then
    warn "Cleanup: secret ${SMOKE_NAMESPACE}/${CERT_SECRET} could not be deleted; remove it manually."
  fi

  if [[ "${NAMESPACE_CREATED}" == "true" ]]; then
    if ! kubectl delete namespace "${SMOKE_NAMESPACE}" --ignore-not-found --wait=false >/dev/null 2>&1; then
      warn "Cleanup: namespace ${SMOKE_NAMESPACE} could not be deleted; remove it manually."
    fi
  fi

  return "${exit_code}"
}

# Status-only, secret-safe diagnostics.
show_diagnostics() {
  local out=""

  warn "Certificate conditions:"
  out="$(kubectl -n "${SMOKE_NAMESPACE}" get certificate "${CERT_NAME}" \
    -o jsonpath='{range .status.conditions[*]}  {.type}={.status} reason={.reason} message={.message}{"\n"}{end}' \
    2>/dev/null || true)"
  if [[ -n "${out}" ]]; then
    echo "${out}" >&2
  fi

  warn "Orders:"
  out="$(kubectl -n "${SMOKE_NAMESPACE}" get orders.acme.cert-manager.io \
    -o jsonpath='{range .items[*]}  {.metadata.name} state={.status.state} reason={.status.reason}{"\n"}{end}' \
    2>/dev/null || true)"
  if [[ -n "${out}" ]]; then
    echo "${out}" >&2
  fi

  warn "Challenges:"
  out="$(kubectl -n "${SMOKE_NAMESPACE}" get challenges.acme.cert-manager.io \
    -o jsonpath='{range .items[*]}  {.metadata.name} type={.spec.type} dnsName={.spec.dnsName} state={.status.state} reason={.status.reason}{"\n"}{end}' \
    2>/dev/null || true)"
  if [[ -n "${out}" ]]; then
    echo "${out}" >&2
  fi

  warn "Next step: kubectl -n cert-manager logs deploy/cert-manager --tail=100 (DNS-01/Cloudflare errors appear here)."
  return 0
}

log "=== CH04 staging certificate issuance smoke check ==="

command -v kubectl >/dev/null 2>&1 || die "kubectl not available"

if [[ "${PLATFORMINIT_ALLOW_STAGING_CERT_SMOKE:-}" != "true" ]]; then
  die "Refusing to create cluster resources. Set PLATFORMINIT_ALLOW_STAGING_CERT_SMOKE=true to acknowledge the bounded staging smoke check."
fi

# --- Input validation: must all pass before the first cluster call ---
[[ -n "${RUN_ID}" ]] || die "SMOKE_RUN_ID must contain at least one DNS-1123 character (a-z, 0-9, '-')."
[[ -n "${SMOKE_NAMESPACE_PREFIX}" ]] || die "SMOKE_NAMESPACE_PREFIX must not be empty."
[[ "${SMOKE_NAMESPACE_PREFIX}" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || die "SMOKE_NAMESPACE_PREFIX '${SMOKE_NAMESPACE_PREFIX}' is not a valid DNS-1123 label."
(( ${#SMOKE_NAMESPACE} <= 63 )) || die "Run-owned namespace '${SMOKE_NAMESPACE}' is ${#SMOKE_NAMESPACE} characters, above the 63-character DNS-1123 limit. Shorten SMOKE_NAMESPACE_PREFIX or SMOKE_RUN_ID."

[[ "${SMOKE_TIMEOUT}" =~ ^[0-9]+$ ]] || die "SMOKE_TIMEOUT must be an integer number of seconds (got '${SMOKE_TIMEOUT}')."
(( SMOKE_TIMEOUT >= SMOKE_TIMEOUT_MIN )) || die "SMOKE_TIMEOUT=${SMOKE_TIMEOUT}s is below the minimum ${SMOKE_TIMEOUT_MIN}s; a shorter budget would abandon the ACME DNS-01 exchange instead of proving issuance."
(( SMOKE_TIMEOUT <= SMOKE_TIMEOUT_MAX )) || die "SMOKE_TIMEOUT=${SMOKE_TIMEOUT}s exceeds the maximum ${SMOKE_TIMEOUT_MAX}s; a bounded smoke check must not hold an operator session indefinitely."

[[ -f "${SMOKE_MANIFEST}" ]] || die "Smoke manifest not found: ${SMOKE_MANIFEST}"

if ! grep -Eq "^[[:space:]]*name:[[:space:]]*${SMOKE_ISSUER}[[:space:]]*$" "${SMOKE_MANIFEST}"; then
  die "Smoke manifest does not reference the ${SMOKE_ISSUER} ClusterIssuer (production issuers are never used by this smoke check)."
fi

if ! kubectl get nodes >/dev/null 2>&1; then
  die "kubectl cannot reach the cluster (check KUBECONFIG)."
fi

if ! kubectl get clusterissuer "${SMOKE_ISSUER}" >/dev/null 2>&1; then
  die "ClusterIssuer ${SMOKE_ISSUER} not found (wait for Argo CD to reconcile the cert-manager issuers)."
fi

trap cleanup EXIT

# Refuse collisions: this run never adopts, overwrites or deletes an object that
# it did not create. A fresh SMOKE_RUN_ID yields a fresh run-owned namespace.
if kubectl get namespace "${SMOKE_NAMESPACE}" >/dev/null 2>&1; then
  die "Refusing to reuse existing namespace '${SMOKE_NAMESPACE}'. Re-run with a fresh SMOKE_RUN_ID (or leave SMOKE_RUN_ID unset) so this run owns every resource it touches."
fi

log "Run id: ${RUN_ID} | namespace: ${SMOKE_NAMESPACE} | timeout: ${SMOKE_TIMEOUT}s | issuer: ${SMOKE_ISSUER}"

kubectl create namespace "${SMOKE_NAMESPACE}" >/dev/null
NAMESPACE_CREATED=true
RUN_STARTED=true
log "Namespace ${SMOKE_NAMESPACE} created for run ${RUN_ID} (removed on cleanup)."

# Render the committed smoke manifest: the namespace and every object name carry
# the run identity and the run label is added, so cleanup can only ever reach
# resources created by this run. The DNS name and the staging issuer stay single
# sourced in Git.
RENDERED_MANIFEST="$(sed -E \
  -e "s|^(  )name: ${SMOKE_NAMESPACE_COMMITTED}$|\1name: ${SMOKE_NAMESPACE}|" \
  -e "s|^(  )namespace: ${SMOKE_NAMESPACE_COMMITTED}$|\1namespace: ${SMOKE_NAMESPACE}|" \
  -e "s|^(  )name: ${CERT_NAME_COMMITTED}$|\1name: ${CERT_NAME}|" \
  -e "s|^(  )secretName: ${CERT_SECRET_COMMITTED}$|\1secretName: ${CERT_SECRET}|" \
  -e "/^    platforminit.io\/purpose: cert-manager-smoke$/a\\
    ${SMOKE_RUN_LABEL}: ${RUN_ID}" \
  "${SMOKE_MANIFEST}")"

if ! grep -q "^  namespace: ${SMOKE_NAMESPACE}$" <<<"${RENDERED_MANIFEST}"; then
  die "Failed to render the smoke manifest for namespace ${SMOKE_NAMESPACE}."
fi

if ! grep -q "^  name: ${CERT_NAME}$" <<<"${RENDERED_MANIFEST}"; then
  die "Failed to render the run-owned Certificate name ${CERT_NAME}."
fi

if ! grep -qF "${SMOKE_RUN_LABEL}: ${RUN_ID}" <<<"${RENDERED_MANIFEST}"; then
  die "Failed to label the smoke resources with run id ${RUN_ID}; refusing to create objects this run does not own."
fi

log "Applying staging Certificate ${CERT_NAME}..."
kubectl apply -f - <<<"${RENDERED_MANIFEST}" >/dev/null

READY_STATUS=""
READY_REASON=""
DEADLINE=$((SECONDS + SMOKE_TIMEOUT))
while ((SECONDS < DEADLINE)); do
  READY_STATUS="$(kubectl -n "${SMOKE_NAMESPACE}" get certificate "${CERT_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)"
  if [[ "${READY_STATUS}" == "True" ]]; then
    break
  fi
  sleep 5
done

if [[ "${READY_STATUS}" == "True" ]]; then
  NOT_AFTER="$(kubectl -n "${SMOKE_NAMESPACE}" get certificate "${CERT_NAME}" \
    -o jsonpath='{.status.notAfter}' 2>/dev/null || true)"
  pass "Certificate ${SMOKE_NAMESPACE}/${CERT_NAME} is Ready=True (staging issuance completed; notAfter=${NOT_AFTER:-unknown})"

  if kubectl -n "${SMOKE_NAMESPACE}" get secret "${CERT_SECRET}" >/dev/null 2>&1; then
    pass "TLS Secret ${SMOKE_NAMESPACE}/${CERT_SECRET} was issued (contents never printed)"
  else
    fail "TLS Secret ${SMOKE_NAMESPACE}/${CERT_SECRET} missing although the Certificate reported Ready"
  fi
else
  READY_REASON="$(kubectl -n "${SMOKE_NAMESPACE}" get certificate "${CERT_NAME}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null || true)"
  fail "Certificate ${SMOKE_NAMESPACE}/${CERT_NAME} did not reach Ready=True within ${SMOKE_TIMEOUT}s (last status: '${READY_STATUS:-unknown}', reason: '${READY_REASON:-unknown}')"
  show_diagnostics
fi

log "=== Summary: PASS=${PASS} FAIL=${FAIL} ==="

if [[ ${FAIL} -gt 0 ]]; then
  die "${FAIL} check(s) failed"
fi

log "CH04 staging certificate issuance smoke check passed"
