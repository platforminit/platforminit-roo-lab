#!/usr/bin/env bash
set -euo pipefail

############################################
# CH02 - Argo CD Bootstrap (idempotent)
############################################

log(){ echo "[ARGO][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run as root (sudo)."

BASE_DIR="${BASE_DIR:-/srv/ch02/gitops-bootstrap}"
MANIFEST_DIR="${BASE_DIR}/manifests"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
DOMAIN="${ARGOCD_DOMAIN:-argocd.${BASE_DOMAIN}}"
ARGO_VERSION="${ARGO_VERSION:-v2.8.4}"
ARGO_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGO_VERSION}/manifests/install.yaml"

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"
}

render_manifests() {
  install -d -m 0755 "${MANIFEST_DIR}"

  cat > "${MANIFEST_DIR}/argocd-certificate.yaml" <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: argocd-tls
  namespace: argocd
spec:
  secretName: argocd-tls
  dnsNames:
  - ${DOMAIN}
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
EOF

  cat > "${MANIFEST_DIR}/argocd-ingress.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd
  namespace: argocd
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec:
  ingressClassName: traefik
  tls:
  - hosts:
    - ${DOMAIN}
    secretName: argocd-tls
  rules:
  - host: ${DOMAIN}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 80
EOF
}

ensure_argocd_server_insecure() {
  log "Set argocd-server ingress mode (server.insecure=true)..."
  kubectl -n argocd patch configmap argocd-cmd-params-cm \
    --type merge \
    -p '{"data":{"server.insecure":"true"}}' >/dev/null

  kubectl -n argocd rollout restart deploy/argocd-server >/dev/null
  kubectl -n argocd rollout status deploy/argocd-server --timeout=600s
}

need kubectl

log "Ensure namespace argocd..."
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Install/upgrade Argo CD ${ARGO_VERSION} ..."
kubectl apply -n argocd -f "${ARGO_INSTALL_URL}"

ensure_argocd_server_insecure

log "Wait for Argo CD core workloads..."
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=600s
kubectl -n argocd rollout status deploy/argocd-applicationset-controller --timeout=600s
kubectl -n argocd rollout status deploy/argocd-notifications-controller --timeout=600s
kubectl -n argocd rollout status statefulset/argocd-application-controller --timeout=600s

log "Render + apply Argo CD ingress manifests..."
render_manifests
kubectl apply -f "${MANIFEST_DIR}/argocd-certificate.yaml"
kubectl apply -f "${MANIFEST_DIR}/argocd-ingress.yaml"

log "Argo CD bootstrap done: https://${DOMAIN}"
