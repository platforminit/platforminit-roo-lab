#!/usr/bin/env bash
set -euo pipefail

if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi
# PlatformInit k3s storage contract:
# k3s data must live under /srv/data/k3s so local-path PVC storage does not
# silently grow on the wrong filesystem/partition.
PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv/data}"
K3S_DATA_DIR="${K3S_DATA_DIR:-${PLATFORMINIT_DATA_PATH}/k3s}"
log(){ echo "[CH02-RESET][$(date -u +%FT%TZ)] $*"; }
[[ $EUID -eq 0 ]] || { echo 'Run as root (sudo).' >&2; exit 1; }
log "Stopping and uninstalling existing k3s state if present..."
/usr/local/bin/k3s-uninstall.sh || true
/usr/local/bin/k3s-killall.sh || true
systemctl stop k3s || true
systemctl disable k3s || true
log "Removing stale CH02 and k3s state..."
rm -rf /etc/rancher/k3s \
       /var/lib/rancher/k3s \
       /var/lib/kubelet \
       /var/lib/cni \
       /etc/cni/net.d \
       /run/k3s \
       "${K3S_DATA_DIR}" \
       /srv/ch02
log "Recreating clean ${K3S_DATA_DIR} ..."
install -d -m 0755 "${K3S_DATA_DIR}"
log "Clean-slate reset complete."
