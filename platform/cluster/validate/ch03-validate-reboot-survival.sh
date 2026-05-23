#!/usr/bin/env bash
set -euo pipefail

############################################
# CH03-06 - Reboot Survival Validation
# Validates that k3s survives a host reboot:
#   - k3s service is enabled for auto-start
#   - data-dir persists on /srv
#   - kubeconfig is accessible after boot
#   - node becomes Ready after reboot
#   - Traefik service recovers
#
# Run AFTER a host reboot to validate survival.
# Does NOT trigger a reboot itself.
############################################

log()  { echo "[$(date -u +%FT%TZ)] [VAL] $*"; }
warn() { echo "[$(date -u +%FT%TZ)] [VAL][WARN] $*" >&2; }
die()  { echo "[$(date -u +%FT%TZ)] [VAL][FAIL] $*" >&2; exit 1; }
pass() { log "PASS: $*"; }

PASS=0
FAIL=0

check() {
  local desc="$1"
  shift
  if "$@"; then
    pass "${desc}"
    PASS=$((PASS + 1))
  else
    die "${desc}"
  fi
}

# --- Preflight ---

if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi

PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv/data}"
K3S_DATA_DIR="${K3S_DATA_DIR:-${PLATFORMINIT_DATA_PATH}/k3s}"

log "=== CH03 Reboot Survival Validation ==="

# 1. Host uptime (informational)
uptime_seconds="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "unknown")"
log "Host uptime: ${uptime_seconds}s"

# 2. k3s service is enabled (will start on boot)
check "k3s service enabled for auto-start" systemctl is-enabled --quiet k3s

# 3. k3s service is active (post-boot)
check "k3s service active after boot" systemctl is-active --quiet k3s

# 4. data-dir persists on /srv
check "data-dir exists after reboot: ${K3S_DATA_DIR}" test -d "${K3S_DATA_DIR}"

# 5. data-dir is on /srv filesystem
data_dir_fs="$(df --output=target "${K3S_DATA_DIR}" 2>/dev/null | tail -n1 || true)"
if [[ "${data_dir_fs}" == /srv* ]]; then
  pass "data-dir is on /srv filesystem: ${data_dir_fs}"
  PASS=$((PASS + 1))
else
  warn "data-dir filesystem: ${data_dir_fs} (expected /srv*)"
fi

# 6. kubeconfig accessible
check "kubeconfig exists after reboot" test -f /etc/rancher/k3s/k3s.yaml

# 7. node becomes Ready
if command -v kubectl >/dev/null 2>&1; then
  if kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null 2>&1; then
    pass "node Ready after reboot"
    PASS=$((PASS + 1))
  else
    die "node not Ready within timeout after reboot"
  fi
else
  die "kubectl not available after reboot"
fi

# 8. kubectl can access cluster (explicit conditional, not redirected check call)
if command -v kubectl >/dev/null 2>&1; then
  if kubectl get nodes >/dev/null 2>&1; then
    pass "kubectl can access cluster after reboot"
    PASS=$((PASS + 1))
  else
    die "kubectl cannot access cluster after reboot"
  fi
else
  die "kubectl not available after reboot"
fi

# 9. Traefik service recovered (hard failure — service exposure is required by contract)
if command -v kubectl >/dev/null 2>&1; then
  if kubectl -n kube-system get svc traefik >/dev/null 2>&1; then
    pass "Traefik service exists after reboot"
    PASS=$((PASS + 1))

    # 10. Traefik pods Ready (hard failure)
    if kubectl -n kube-system rollout status deploy/traefik --timeout=180s >/dev/null 2>&1; then
      pass "Traefik deployment rolled out after reboot"
      PASS=$((PASS + 1))
    else
      die "Traefik rollout did not complete within timeout after reboot"
    fi
  else
    die "Traefik service not found after reboot"
  fi
else
  die "kubectl not available (cannot validate Traefik recovery after reboot)"
fi

# 11. Systemd journal for k3s (check for boot-time errors)
if command -v journalctl >/dev/null 2>&1; then
  boot_id="$(journalctl --list-boots 2>/dev/null | tail -n1 | awk '{print $1}' || true)"
  if [[ -n "${boot_id}" ]]; then
    if journalctl -u k3s -b "${boot_id}" --no-pager -q 2>/dev/null | grep -qi "error\|failed\|fatal"; then
      warn "k3s journal contains error/failed/fatal entries from current boot"
    else
      pass "k3s journal clean (no error/failed/fatal entries)"
      PASS=$((PASS + 1))
    fi
  fi
fi

# --- Summary ---

log "=== Summary: PASS=${PASS} FAIL=${FAIL} ==="

if [[ ${FAIL} -gt 0 ]]; then
  die "${FAIL} check(s) failed"
fi

log "CH03 reboot survival validation PASSED"
