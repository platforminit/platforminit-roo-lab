#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Uninstalling k3s..."
/usr/local/bin/k3s-uninstall.sh || true

echo "[INFO] Removing data dir..."
if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi
PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv}"
rm -rf "${K3S_DATA_DIR:-${PLATFORMINIT_DATA_PATH}/k3s}"

echo "[DONE]"
