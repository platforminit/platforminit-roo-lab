#!/usr/bin/env bash
set -euo pipefail

############################################
# CH03-02 - k3s Uninstall
# Guarded removal with explicit safety checks
############################################

log()  { echo "[$(date -u +%FT%TZ)] [INFO] $*"; }
warn() { echo "[$(date -u +%FT%TZ)] [WARN] $*" >&2; }
die()  { echo "[$(date -u +%FT%TZ)] [ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (sudo)."

if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi

# PlatformInit k3s storage contract:
# k3s data must live under /srv/data/k3s.
PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv/data}"
K3S_DATA_DIR="${K3S_DATA_DIR:-${PLATFORMINIT_DATA_PATH}/k3s}"

# Guard: only allow the expected contract path by default.
# For alternate paths, the operator must explicitly set
# K3S_DATA_DIR_ALLOW_UNSAFE=true to confirm the risk.
EXPECTED_DATA_DIR="/srv/data/k3s"

if [[ "${K3S_DATA_DIR}" != "${EXPECTED_DATA_DIR}" ]]; then
  if [[ "${K3S_DATA_DIR_ALLOW_UNSAFE:-false}" != "true" ]]; then
    die "Refusing to remove data-dir: K3S_DATA_DIR=${K3S_DATA_DIR} (expected ${EXPECTED_DATA_DIR}). Set K3S_DATA_DIR_ALLOW_UNSAFE=true to override."
  fi
  warn "K3S_DATA_DIR_ALLOW_UNSAFE=true: removing non-standard data-dir ${K3S_DATA_DIR}"
fi

# Additional safety: reject empty or root paths regardless of override
if [[ -z "${K3S_DATA_DIR}" || "${K3S_DATA_DIR}" == "/" ]]; then
  die "Refusing to remove data-dir: K3S_DATA_DIR=${K3S_DATA_DIR} is unsafe"
fi

log "Uninstalling k3s..."
/usr/local/bin/k3s-uninstall.sh || true

log "Removing data dir: ${K3S_DATA_DIR}"
rm -rf "${K3S_DATA_DIR}"

log "k3s uninstall complete."
