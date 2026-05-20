#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[$(basename "$0")][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
OPERATIONS_NAMESPACE="${OPERATIONS_NAMESPACE:-operations}"
PLATFORM_REPO_URL="${PLATFORM_REPO_URL:-https://github.com/platforminit/platforminit-platform.git}"
TARGET_REVISION="${TARGET_REVISION:-dev}"
BASE_DOMAIN="${BASE_DOMAIN:-}"
TLS_ISSUER="${TLS_ISSUER:-letsencrypt-prod}"
export KUBECONFIG
need kubectl
[ -f "$KUBECONFIG" ] || die "Missing kubeconfig: $KUBECONFIG"
kubectl get nodes >/dev/null
kubectl get ns "$ARGOCD_NAMESPACE" >/dev/null 2>&1 || die "Missing Argo CD namespace: $ARGOCD_NAMESPACE. Run CH04 first."
[[ -n "$BASE_DOMAIN" ]] || die "Missing BASE_DOMAIN. Set the PLATFORM_BASE_DOMAIN secret or workflow input; do not hardcode domains in CH05."
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
sed -e "s#__REPO_URL__#${PLATFORM_REPO_URL}#g" \
    -e "s#__TARGET_REVISION__#${TARGET_REVISION}#g" \
    -e "s#__BASE_DOMAIN__#${BASE_DOMAIN}#g" \
    -e "s#__TLS_ISSUER__#${TLS_ISSUER}#g" \
    "$REPO_ROOT/argocd/operations-stack-application.yaml.tpl" > "$WORKDIR/operations-stack-application.yaml"
log "Applying Operations AppProject"
kubectl apply -f "$REPO_ROOT/argocd/operations-project.yaml"
log "Registering Argo CD Application operations-stack targetRevision=${TARGET_REVISION}"
kubectl apply -f "$WORKDIR/operations-stack-application.yaml"
# CH05 must not auto-sync before 05.1 prerequisite secrets exist.
# Keep the Application registered and OutOfSync until 05.2 explicitly requests a sync.
# Use JSON patch first because older generated Applications may already carry spec.syncPolicy.automated.
kubectl -n "$ARGOCD_NAMESPACE" patch application.argoproj.io operations-stack \
  --type json \
  -p '[{"op":"remove","path":"/spec/syncPolicy/automated"}]' >/dev/null 2>&1 || true
kubectl -n "$ARGOCD_NAMESPACE" patch application.argoproj.io operations-stack \
  --type merge \
  -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null 2>&1 || true
log "Operations stack registered under Argo CD ownership; automated sync disabled by design"
kubectl -n "$ARGOCD_NAMESPACE" get app operations-stack -o wide || true
