#!/usr/bin/env bash
set -euo pipefail

############################################
# CH03-03 - kubeconfig for devops user
# Post-install kubeconfig access contract
############################################

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
# To force DNS endpoint, export K3S_API_ENDPOINT before running:
#   export K3S_API_ENDPOINT="https://k3s.sysadminhomelab.hu:6443"
if [[ -n "${K3S_API_ENDPOINT:-}" ]]; then
  # Security: validate endpoint format before interpolation into perl
  if ! echo "${K3S_API_ENDPOINT}" | grep -qE '^https://[A-Za-z0-9._:-]+(:[0-9]+)?$'; then
    die "Invalid K3S_API_ENDPOINT: ${K3S_API_ENDPOINT}. Must match ^https://[A-Za-z0-9._:-]+(:[0-9]+)?$"
  fi
  endpoint="${K3S_API_ENDPOINT}"
fi

log "Creating ${kcfg_dir} ..."
install -d -m 0700 -o "${user}" -g "${user}" "${kcfg_dir}"

log "Copying kubeconfig to ${kcfg_dst} ..."
install -m 0600 -o "${user}" -g "${user}" "${kcfg_src}" "${kcfg_dst}"

log "Rewriting API endpoint to ${endpoint} ..."
# Use perl with $ENV{} to avoid shell interpolation into the regex expression
export PERL_ENDPOINT="${endpoint}"
perl -pi -e 's|^(\s*server:\s*)https://.*$|${1}$ENV{PERL_ENDPOINT}|m' "${kcfg_dst}" || true

# optional bashrc export
bashrc="${home}/.bashrc"
if ! grep -qs 'export KUBECONFIG=\$HOME/.kube/config' "${bashrc}" 2>/dev/null; then
  echo 'export KUBECONFIG=$HOME/.kube/config' >> "${bashrc}"
fi

log "Smoke: current context (root-assisted, user kubeconfig)"
KUBECONFIG="${kcfg_dst}" kubectl config current-context || true

log "Smoke: cluster-info (root-assisted, user kubeconfig)"
KUBECONFIG="${kcfg_dst}" kubectl cluster-info || true
