#!/usr/bin/env bash
set -euo pipefail

user="${1:-devops}"
die(){ echo "FATAL: $*" >&2; exit 1; }
log(){ echo "[INFO] $*"; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."
id "${user}" >/dev/null 2>&1 || die "User not found: ${user}"

home="$(getent passwd "${user}" | cut -d: -f6)"
kcfg_dir="${home}/.kube"
kcfg_dst="${kcfg_dir}/config"
kcfg_src="/etc/rancher/k3s/k3s.yaml"

endpoint="https://127.0.0.1:6443"
# If you want to force DNS endpoint, export K3S_API_ENDPOINT before running:
# export K3S_API_ENDPOINT="https://k3s.sysadminhomelab.hu:6443"
if [[ -n "${K3S_API_ENDPOINT:-}" ]]; then
  endpoint="${K3S_API_ENDPOINT}"
fi

log "Creating ${kcfg_dir} ..."
install -d -m 0700 -o "${user}" -g "${user}" "${kcfg_dir}"

log "Copying kubeconfig to ${kcfg_dst} ..."
install -m 0600 -o "${user}" -g "${user}" "${kcfg_src}" "${kcfg_dst}"

log "Rewriting API endpoint to ${endpoint} (URL-safe perl) ..."
perl -pi -e "s|^(\s*server:\s*)https://.*\$|\${1}${endpoint}|m" "${kcfg_dst}" || true

# optional bashrc export
bashrc="${home}/.bashrc"
if ! grep -qs 'export KUBECONFIG=\$HOME/.kube/config' "${bashrc}" 2>/dev/null; then
  echo 'export KUBECONFIG=$HOME/.kube/config' >> "${bashrc}"
fi

log "Smoke: current context (root-assisted, user kubeconfig)"
KUBECONFIG="${kcfg_dst}" kubectl config current-context || true

log "Smoke: cluster-info (root-assisted, user kubeconfig)"
KUBECONFIG="${kcfg_dst}" kubectl cluster-info || true
