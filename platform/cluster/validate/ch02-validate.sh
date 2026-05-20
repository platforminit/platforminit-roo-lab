#!/usr/bin/env bash
set -euo pipefail

############################################
# CH02 Validation
# Returns non-zero on FAIL.
############################################

log() { echo "[VAL] $*"; }
die() { echo "[VAL][FAIL] $*" >&2; exit 1; }

if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi
# PlatformInit k3s storage contract:
# k3s data must live under /srv/data/k3s.
PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv/data}"
K3S_DATA_DIR="${K3S_DATA_DIR:-${PLATFORMINIT_DATA_PATH}/k3s}"

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"
}

servicelb_disabled() {
  if systemctl cat k3s 2>/dev/null | grep -Eq -- '--disable(=|[[:space:]]+)servicelb'; then
    return 0
  fi

  if [[ -f /etc/rancher/k3s/config.yaml ]] && \
     grep -Eq '^\s*disable:\s*.*servicelb|^\s*-\s*servicelb\s*$' /etc/rancher/k3s/config.yaml; then
    return 0
  fi

  return 1
}

validate_traefik_exposure() {
  local svc_type lb_ip lb_hostname lb_endpoint

  svc_type="$(kubectl -n kube-system get svc traefik -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  [[ -n "${svc_type}" ]] || die "Traefik service missing"

  if [[ "${svc_type}" != "LoadBalancer" ]]; then
    die "Unexpected Traefik service type: ${svc_type} (expected LoadBalancer)"
  fi

  servicelb_disabled && die "k3s has ServiceLB disabled (--disable servicelb)"

  kubectl -n kube-system wait --for=condition=Ready pod -l svccontroller.k3s.cattle.io/svcname=traefik --timeout=240s \
    || die "svclb-traefik pods not Ready"

  lb_ip="$(kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  lb_hostname="$(kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "${lb_ip}" || -n "${lb_hostname}" ]] || die "Traefik EXTERNAL-IP still pending"

  lb_endpoint="${lb_ip:-${lb_hostname}}"

  if command -v curl >/dev/null 2>&1; then
    if ! curl -sSI --max-time 5 "http://127.0.0.1" >/dev/null && \
       ! curl -sSI --max-time 5 "http://${lb_endpoint}" >/dev/null; then
      die "Traefik HTTP probe failed on localhost and ${lb_endpoint}"
    fi
  fi
}

need kubectl
need systemctl

log "k3s service active"
systemctl is-active --quiet k3s || die "k3s.service not active"

log "k3s data-dir path"
[[ -d "$K3S_DATA_DIR" ]] || die "Missing k3s data-dir: $K3S_DATA_DIR"
if [[ -f /etc/rancher/k3s/config.yaml ]]; then
  grep -Fq "data-dir: ${K3S_DATA_DIR}" /etc/rancher/k3s/config.yaml || die "k3s config data-dir does not match expected path: $K3S_DATA_DIR"
fi

log "node Ready"
kubectl wait --for=condition=Ready node --all --timeout=180s

log "Traefik rollout"
kubectl -n kube-system rollout status deploy/traefik --timeout=300s

log "Traefik exposure (LoadBalancer + ServiceLB)"
validate_traefik_exposure

log "cert-manager pods Ready (if installed)"
if kubectl get ns cert-manager >/dev/null 2>&1; then
  kubectl -n cert-manager get deploy cert-manager cert-manager-webhook cert-manager-cainjector >/dev/null 2>&1 \
    || die "cert-manager deployments missing"
  kubectl -n cert-manager rollout status deploy/cert-manager --timeout=300s
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
  kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=300s
fi

log "ClusterIssuers present"
kubectl get clusterissuer letsencrypt-staging >/dev/null 2>&1 || die "Missing ClusterIssuer: letsencrypt-staging"
kubectl get clusterissuer letsencrypt-prod >/dev/null 2>&1 || die "Missing ClusterIssuer: letsencrypt-prod"

log "Argo CD server Ready"
kubectl get ns argocd >/dev/null 2>&1 || die "Missing namespace: argocd"
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd get ingress argocd >/dev/null 2>&1 || die "Missing ingress: argocd"
kubectl -n argocd get certificate argocd-tls >/dev/null 2>&1 || die "Missing certificate: argocd-tls"

log "PASS"

