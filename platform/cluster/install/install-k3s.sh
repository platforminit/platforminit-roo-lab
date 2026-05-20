#!/usr/bin/env bash
set -euo pipefail

############################################
# CH02-01 - k3s Single Node Baseline
############################################

K3S_VERSION="v1.29.3+k3s1"
if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi
# PlatformInit k3s storage contract:
# k3s data must live under /srv/data/k3s so local-path PVC storage does not
# silently grow on the wrong filesystem/partition.
PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv/data}"
DATA_DIR="${K3S_DATA_DIR:-${PLATFORMINIT_DATA_PATH}/k3s}"
TLS_DOMAIN="k3s.sysadminhomelab.hu"
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
K3S_DROPIN_DIR="/etc/systemd/system/k3s.service.d"
K3S_DROPIN_FILE="${K3S_DROPIN_DIR}/10-args.conf"

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "[ERROR] This script must run as root (use sudo)." >&2
    exit 1
  fi
}

ensure_pkg() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends curl ca-certificates >/dev/null
}

is_k3s_installed() {
  command -v k3s >/dev/null 2>&1 && systemctl list-unit-files | grep -q '^k3s\.service'
}

current_k3s_version() {
  if command -v k3s >/dev/null 2>&1; then
    k3s --version 2>/dev/null | awk '{print $3}' | head -n1 || true
  fi
}

ensure_kubectl_link() {
  if command -v kubectl >/dev/null 2>&1; then
    return 0
  fi
  if command -v k3s >/dev/null 2>&1; then
    ln -sf "$(command -v k3s)" /usr/local/bin/kubectl
  fi
}

write_k3s_config() {
  install -d -m 0755 /etc/rancher/k3s
  {
    echo "data-dir: ${DATA_DIR}"
    echo 'write-kubeconfig-mode: "644"'
    echo "tls-san:"
    echo "  - ${TLS_DOMAIN}"
    if [[ -n "${PUBLIC_IP:-}" ]]; then
      echo "  - ${PUBLIC_IP}"
    fi
  } > "${K3S_CONFIG}"
}

write_k3s_dropin() {
  install -d -m 0755 "${K3S_DROPIN_DIR}"
  cat > "${K3S_DROPIN_FILE}" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/bin/k3s server
EOF
}

restart_k3s() {
  systemctl daemon-reload
  systemctl enable k3s >/dev/null
  systemctl restart k3s >/dev/null
}

need_root
ensure_pkg

echo "[INFO] Detecting public IP..."
PUBLIC_IP=$(curl -fsS https://api.ipify.org || true)

if is_k3s_installed; then
  INSTALLED_VER="$(current_k3s_version)"
  if [[ "${INSTALLED_VER}" == "${K3S_VERSION}" ]]; then
    echo "[INFO] k3s already installed (${INSTALLED_VER}). Ensuring config and service state..."
  else
    echo "[WARN] k3s installed but version mismatch (installed=${INSTALLED_VER}, desired=${K3S_VERSION})."
    echo "[WARN] Not auto-upgrading. If you want to upgrade, run /srv/ch02/uninstall-k3s.sh then re-run."
  fi

  write_k3s_config
  write_k3s_dropin
  restart_k3s
  ensure_kubectl_link
else
  echo "[INFO] Creating data directory..."
  mkdir -p "${DATA_DIR}"

  write_k3s_config

  echo "[INFO] Installing k3s ${K3S_VERSION} ..."
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="${K3S_VERSION}" \
    INSTALL_K3S_EXEC="server" \
    sh -

  write_k3s_dropin
  restart_k3s
fi

sleep 10
ensure_kubectl_link

echo "[INFO] Waiting for node to become Ready..."
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get nodes -o wide

echo "[SUCCESS] k3s installation complete."
