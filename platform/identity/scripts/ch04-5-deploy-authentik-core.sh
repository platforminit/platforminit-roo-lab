#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH04.5][AUTHENTIK_CORE][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

DEPLOY_MODE="${DEPLOY_MODE:-baseline}"
ISSUER_MODE="${ISSUER_MODE:-staging}"
BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
NAMESPACE="${NAMESPACE:-identity}"
AUTHENTIK_CHART_VERSION="${AUTHENTIK_CHART_VERSION:-2026.2.2}"
AUTHENTIK_BOOTSTRAP_EMAIL="${AUTHENTIK_BOOTSTRAP_EMAIL:-admin@${BASE_DOMAIN}}"
AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN:-}"

case "${DEPLOY_MODE}" in
  baseline|reconcile) ;;
  *) die "DEPLOY_MODE must be baseline or reconcile, got: ${DEPLOY_MODE}" ;;
esac

case "${ISSUER_MODE}" in
  staging|prod) ;;
  *) die "ISSUER_MODE must be staging or prod, got: ${ISSUER_MODE}" ;;
esac

CLUSTER_ISSUER="letsencrypt-${ISSUER_MODE}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

require_secret_env() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || die "Missing required secret/env: ${name}"
}

ensure_runtime_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y >/dev/null
  apt-get install -y --no-install-recommends curl ca-certificates gnupg rsync openssl >/dev/null
}

ensure_helm() {
  if command -v helm >/dev/null 2>&1; then
    return 0
  fi
  log "Installing helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash >/dev/null
}

ensure_cluster_ready() {
  need kubectl
  [ -f "${KUBECONFIG}" ] || die "Missing kubeconfig: ${KUBECONFIG}"
  kubectl --kubeconfig "${KUBECONFIG}" get nodes >/dev/null 2>&1 || die "kubectl cannot access cluster via ${KUBECONFIG}"
}

ensure_namespace() {
  kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || kubectl create namespace "${NAMESPACE}"
  kubectl label ns "${NAMESPACE}" app.kubernetes.io/part-of=platforminit --overwrite >/dev/null
}

resolve_bootstrap_token() {
  if [[ -n "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]]; then
    return 0
  fi

  if kubectl -n "${NAMESPACE}" get secret authentik-bootstrap >/dev/null 2>&1; then
    AUTHENTIK_BOOTSTRAP_TOKEN="$(kubectl -n "${NAMESPACE}" get secret authentik-bootstrap -o jsonpath='{.data.AUTHENTIK_BOOTSTRAP_TOKEN}' 2>/dev/null | base64 -d || true)"
  fi

  if [[ -z "${AUTHENTIK_BOOTSTRAP_TOKEN}" ]]; then
    AUTHENTIK_BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"
  fi
}

apply_secrets() {
  require_secret_env AUTHENTIK_SECRET_KEY
  require_secret_env AUTHENTIK_POSTGRESQL_PASSWORD
  require_secret_env AUTHENTIK_BOOTSTRAP_PASSWORD
  resolve_bootstrap_token

  kubectl -n "${NAMESPACE}" create secret generic authentik-core \
    --from-literal=secret-key="${AUTHENTIK_SECRET_KEY}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl -n "${NAMESPACE}" create secret generic authentik-postgresql-credentials \
    --from-literal=password="${AUTHENTIK_POSTGRESQL_PASSWORD}" \
    --from-literal=postgres-password="${AUTHENTIK_POSTGRESQL_PASSWORD}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  kubectl -n "${NAMESPACE}" create secret generic authentik-bootstrap \
    --from-literal=AUTHENTIK_BOOTSTRAP_EMAIL="${AUTHENTIK_BOOTSTRAP_EMAIL}" \
    --from-literal=AUTHENTIK_BOOTSTRAP_PASSWORD="${AUTHENTIK_BOOTSTRAP_PASSWORD}" \
    --from-literal=AUTHENTIK_BOOTSTRAP_TOKEN="${AUTHENTIK_BOOTSTRAP_TOKEN}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

install_repos() {
  helm repo add authentik https://charts.goauthentik.io >/dev/null
  helm repo update >/dev/null
}

deploy_authentik() {
  log "Deploying Authentik chart ${AUTHENTIK_CHART_VERSION} into namespace ${NAMESPACE}"
  helm upgrade --install authentik authentik/authentik \
    --namespace "${NAMESPACE}" \
    --version "${AUTHENTIK_CHART_VERSION}" \
    -f "${REPO_ROOT}/values/authentik-values.yaml.tpl" \
    --wait --timeout 20m
}


configure_authentik_public_host() {
  local public_host="https://auth.${BASE_DOMAIN}"
  log "Configuring Authentik public host for embedded outpost: ${public_host}"
  kubectl -n "${NAMESPACE}" set env deployment/authentik-server \
    AUTHENTIK_HOST="${public_host}" \
    AUTHENTIK_HOST_BROWSER="${public_host}" >/dev/null
  kubectl -n "${NAMESPACE}" set env deployment/authentik-worker \
    AUTHENTIK_HOST="${public_host}" \
    AUTHENTIK_HOST_BROWSER="${public_host}" >/dev/null
}

render_apply_ingress() {
  local tmp_dir=""
  tmp_dir="$(mktemp -d)"

  python3 - <<PY
from pathlib import Path
base_domain = "${BASE_DOMAIN}"
cluster_issuer = "${CLUSTER_ISSUER}"
repo = Path("${REPO_ROOT}")
out = Path("${tmp_dir}")
for name in ["authentik-certificate.yaml", "authentik-ingress.yaml"]:
    text = (repo / "ingress" / name).read_text()
    text = text.replace("__BASE_DOMAIN__", base_domain).replace("__CLUSTER_ISSUER__", cluster_issuer)
    (out / name).write_text(text)
PY

  kubectl apply -f "${tmp_dir}/authentik-certificate.yaml"
  kubectl apply -f "${tmp_dir}/authentik-ingress.yaml"
  rm -rf "${tmp_dir}"
}

wait_for_rollouts() {
  log "Waiting for Authentik rollouts"
  kubectl -n "${NAMESPACE}" rollout status statefulset/authentik-postgresql --timeout=600s || true
  kubectl -n "${NAMESPACE}" rollout status deployment/authentik-server --timeout=600s
  kubectl -n "${NAMESPACE}" rollout status deployment/authentik-worker --timeout=600s
}

main() {
  ensure_runtime_deps
  ensure_helm
  ensure_cluster_ready
  ensure_namespace
  apply_secrets
  install_repos
  deploy_authentik
  configure_authentik_public_host
  render_apply_ingress
  wait_for_rollouts
  log "CH04.5 Authentik core deploy completed with deploy_mode=${DEPLOY_MODE} issuer=${CLUSTER_ISSUER} url=https://auth.${BASE_DOMAIN}"
}

main "$@"
