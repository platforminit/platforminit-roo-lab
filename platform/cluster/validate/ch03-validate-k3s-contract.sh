#!/usr/bin/env bash
set -euo pipefail

############################################
# CH03-05 - k3s Install Contract Validation
# Validates:
#   - k3s service active
#   - data-dir follows /srv contract
#   - node Ready
#   - Traefik service exists and exposes ports 80/443
#   - kubectl accessible
#   - kubeconfig accessible post-install
#
# Safe to run on a running host. Does not
# mutate cluster state.
############################################

log()  { echo "[$(date -u +%FT%TZ)] [VAL] $*"; }
warn() { echo "[$(date -u +%FT%TZ)] [VAL][WARN] $*" >&2; }
die()  { echo "[$(date -u +%FT%TZ)] [VAL][FAIL] $*" >&2; exit 1; }
pass() { log "PASS: $*"; }
fail() { die "$*"; }

PASS=0
FAIL=0

check() {
  local desc="$1"
  shift
  if "$@"; then
    pass "${desc}"
    PASS=$((PASS + 1))
  else
    fail "${desc}"
    FAIL=$((FAIL + 1))
  fi
}

# --- Preflight ---

if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi

PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv/data}"
K3S_DATA_DIR="${K3S_DATA_DIR:-${PLATFORMINIT_DATA_PATH}/k3s}"

# --- Checks ---

log "=== CH03 k3s Install Contract Validation ==="

# 1. k3s binary
check "k3s binary installed" command -v k3s

# 2. k3s service active
check "k3s service active" systemctl is-active --quiet k3s

# 3. k3s service enabled
check "k3s service enabled" systemctl is-enabled --quiet k3s

# 4. data-dir exists
check "k3s data-dir exists: ${K3S_DATA_DIR}" test -d "${K3S_DATA_DIR}"

# 5. data-dir follows /srv contract (must be under /srv)
if [[ "${K3S_DATA_DIR}" == /srv/* ]]; then
  pass "data-dir follows /srv contract: ${K3S_DATA_DIR}"
  PASS=$((PASS + 1))
else
  fail "data-dir does NOT follow /srv contract: ${K3S_DATA_DIR}"
fi

# 6. config.yaml has correct data-dir
if [[ -f /etc/rancher/k3s/config.yaml ]]; then
  if grep -Fq "data-dir: ${K3S_DATA_DIR}" /etc/rancher/k3s/config.yaml; then
    pass "config.yaml data-dir matches expected path"
    PASS=$((PASS + 1))
  else
    fail "config.yaml data-dir does not match expected path"
  fi
else
  fail "config.yaml not found at /etc/rancher/k3s/config.yaml"
fi

# 7. node Ready
if command -v kubectl >/dev/null 2>&1; then
  if kubectl wait --for=condition=Ready node --all --timeout=30s >/dev/null 2>&1; then
    pass "all nodes Ready"
    PASS=$((PASS + 1))
  else
    fail "nodes not Ready"
  fi
else
  fail "kubectl not available"
fi

# 8. Traefik service exists (hard failure — service exposure is required by contract)
if command -v kubectl >/dev/null 2>&1; then
  if kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
    pass "Traefik service exists in kube-system"
    PASS=$((PASS + 1))

    # 9. Traefik exposes ports 80 and 443 (hard failure)
    T_PORTS="$(kubectl -n kube-system get svc traefik -o jsonpath='{range .spec.ports[*]}{.port}{" "}{end}' 2>/dev/null || true)"
    if echo " ${T_PORTS} " | grep -q " 80 " && echo " ${T_PORTS} " | grep -q " 443 "; then
      pass "Traefik exposes ports 80 and 443"
      PASS=$((PASS + 1))
    else
      fail "Traefik ports: ${T_PORTS} (expected 80 and 443)"
    fi
  else
    fail "Traefik service not found in kube-system"
  fi
else
  fail "kubectl not available (cannot validate Traefik service exposure)"
fi

# 10. kubeconfig accessible
if [[ -f /etc/rancher/k3s/k3s.yaml ]]; then
  pass "kubeconfig exists at /etc/rancher/k3s/k3s.yaml"
  PASS=$((PASS + 1))
else
  fail "kubeconfig not found at /etc/rancher/k3s/k3s.yaml"
fi

# 11. kubectl can access cluster
if command -v kubectl >/dev/null 2>&1; then
  if kubectl get nodes >/dev/null 2>&1; then
    pass "kubectl can access cluster"
    PASS=$((PASS + 1))
  else
    fail "kubectl cannot access cluster"
  fi
fi

# --- Summary ---

log "=== Summary: PASS=${PASS} FAIL=${FAIL} ==="

if [[ ${FAIL} -gt 0 ]]; then
  die "${FAIL} check(s) failed"
fi

log "CH03 k3s install contract validation PASSED"
