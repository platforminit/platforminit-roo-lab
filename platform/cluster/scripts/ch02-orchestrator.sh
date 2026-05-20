#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH02][$(date -u +%FT%TZ)] $*"; }
die(){ echo "FATAL: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Run as root (sudo)."

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
INSTALL_SH="${REPO_ROOT}/install/install-k3s.sh"
KUBECONFIG_SH="${REPO_ROOT}/install/kubeconfig-devops.sh"
TRAEFIK_CFG_SRC="${REPO_ROOT}/manifests/traefik/traefik-helmchartconfig.yaml"
ARGO_BOOTSTRAP_SH="${REPO_ROOT}/addons/argocd/ch02-argocd-bootstrap.sh"
CLUSTERISSUER_FILE="${REPO_ROOT}/addons/cert-manager/clusterissuer-letsencrypt-cloudflare.yaml"

BASE_DOMAIN="${BASE_DOMAIN:-sysadminhomelab.hu}"
WILDCARD_FQDN="*.${BASE_DOMAIN}"
CLOUDFLARE_API_TOKEN_FILE="${CLOUDFLARE_API_TOKEN_FILE:-/srv/ch01/secrets/cloudflare_api_token}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.14.7}"
CERT_MANAGER_MANIFEST_URL="https://github.com/cert-manager/cert-manager/releases/download/${CERT_MANAGER_VERSION}/cert-manager.yaml"

need() {
  command -v "$1" >/dev/null 2>&1 || die "Missing binary: $1"
}

ensure_runtime_deps() {
  local missing=()
  for b in curl jq; do
    command -v "$b" >/dev/null 2>&1 || missing+=("$b")
  done

  if (( ${#missing[@]} > 0 )); then
    log "Installing missing packages: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null
    apt-get install -y --no-install-recommends "${missing[@]}" >/dev/null
  fi
}

detect_k3s_data_dir() {
  local cfg="/etc/rancher/k3s/config.yaml"
  local data_dir=""

  if [[ -f "${cfg}" ]]; then
    data_dir="$(awk -F': *' '$1=="data-dir" {print $2; exit}' "${cfg}" | tr -d '"' | xargs || true)"
  fi

  if [[ -n "${data_dir}" ]]; then
    echo "${data_dir}"
    return
  fi

  if grep -qs '^K3S_DATA_DIR=' /etc/systemd/system/k3s.service.env 2>/dev/null; then
    data_dir="$(grep -s '^K3S_DATA_DIR=' /etc/systemd/system/k3s.service.env | head -n1 | cut -d= -f2- | tr -d '"')"
  elif [[ -d /srv/data/k3s ]]; then
    data_dir="/srv/data/k3s"
  elif [[ -d /srv/k3s ]]; then
    data_dir="/srv/k3s"
  else
    data_dir="/var/lib/rancher/k3s"
  fi

  echo "${data_dir}"
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

ensure_k3s_install() {
  local stale_dir=""

  if ! systemctl cat k3s >/dev/null 2>&1; then
    [[ -x "${INSTALL_SH}" ]] || die "k3s not installed and installer missing: ${INSTALL_SH}"

    stale_dir="$(detect_k3s_data_dir)"
    if [[ -d "${stale_dir}" ]] && find "${stale_dir}" -mindepth 1 -maxdepth 2 | read -r _; then
      log "k3s service missing, but existing data-dir found at ${stale_dir}. Resetting stale CH02 state..."
      if [[ -x "${REPO_ROOT}/install/uninstall-k3s.sh" ]]; then
        bash "${REPO_ROOT}/install/uninstall-k3s.sh" || true
      else
        /usr/local/bin/k3s-uninstall.sh || true
        rm -rf "${stale_dir}"
      fi
    fi

    log "k3s service missing. Running installer..."
    bash "${INSTALL_SH}"
    return
  fi

  if servicelb_disabled; then
    [[ -x "${INSTALL_SH}" ]] || die "k3s servicelb is disabled and installer missing: ${INSTALL_SH}"
    log "Detected '--disable servicelb'. Repairing k3s config via installer..."
    bash "${INSTALL_SH}"
  fi
}

apply_traefik_config() {
  install -d -m 0755 "${MANIFESTS_DIR}"

  if [[ -f "${TRAEFIK_CFG_SRC}" ]]; then
    install -m 0644 "${TRAEFIK_CFG_SRC}" "${MANIFESTS_DIR}/traefik-helmchartconfig.yaml"
    return
  fi

  cat >"${MANIFESTS_DIR}/traefik-helmchartconfig.yaml" <<'YAML'
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
spec:
  valuesContent: |-
    service:
      type: LoadBalancer
YAML
}


wait_for_deployment_exists() {
  local namespace="$1"
  local name="$2"
  local deadline=$((SECONDS + 240))

  while (( SECONDS < deadline )); do
    if kubectl -n "${namespace}" get deploy "${name}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
  done

  return 1
}

wait_for_svclb_traefik() {
  local deadline=$((SECONDS + 240))

  while (( SECONDS < deadline )); do
    if kubectl -n kube-system get pods -l svccontroller.k3s.cattle.io/svcname=traefik --no-headers 2>/dev/null | grep -q .; then
      return 0
    fi
    sleep 3
  done

  return 1
}

validate_traefik_service_lb() {
  local svc_type lb_ip lb_hostname lb_endpoint

  svc_type="$(kubectl -n kube-system get svc traefik -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  [[ -n "${svc_type}" ]] || die "Traefik service not found in kube-system."

  log "Traefik service type: ${svc_type}"
  if [[ "${svc_type}" != "LoadBalancer" ]]; then
    log "Traefik is not LoadBalancer, skipping svclb checks."
    return 0
  fi

  if servicelb_disabled; then
    die "ServiceLB is disabled in k3s args/config. Remove '--disable servicelb' and restart k3s."
  fi

  log "Waiting for svclb-traefik pods..."
  wait_for_svclb_traefik || die "No svclb-traefik pods found. ServiceLB is not provisioning Traefik."

  kubectl -n kube-system wait --for=condition=Ready pod -l svccontroller.k3s.cattle.io/svcname=traefik --timeout=180s \
    || die "svclb-traefik pod(s) did not become Ready."

  lb_ip="$(kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  lb_hostname="$(kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"

  if [[ -z "${lb_ip}" && -z "${lb_hostname}" ]]; then
    die "Traefik EXTERNAL-IP is still pending (no loadBalancer ingress assigned)."
  fi

  lb_endpoint="${lb_ip:-${lb_hostname}}"
  log "Traefik LB endpoint: ${lb_endpoint}"

  if command -v curl >/dev/null 2>&1; then
    curl -sSI --max-time 5 "http://127.0.0.1" >/dev/null \
      && log "HTTP probe localhost: OK" \
      || log "WARN: HTTP probe localhost failed"

    curl -sSI --max-time 5 "http://${lb_endpoint}" >/dev/null \
      && log "HTTP probe ${lb_endpoint}: OK" \
      || log "WARN: HTTP probe ${lb_endpoint} failed"
  fi
}

ensure_cert_manager() {
  log "Ensure cert-manager (${CERT_MANAGER_VERSION}) ..."
  kubectl apply -f "${CERT_MANAGER_MANIFEST_URL}"

  kubectl -n cert-manager rollout status deploy/cert-manager --timeout=300s
  kubectl -n cert-manager rollout status deploy/cert-manager-webhook --timeout=300s
  kubectl -n cert-manager rollout status deploy/cert-manager-cainjector --timeout=300s
}

read_cloudflare_token() {
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    printf '%s' "${CLOUDFLARE_API_TOKEN}"
    return
  fi

  [[ -f "${CLOUDFLARE_API_TOKEN_FILE}" ]] || die "Missing Cloudflare token file: ${CLOUDFLARE_API_TOKEN_FILE}"
  tr -d '\r\n' < "${CLOUDFLARE_API_TOKEN_FILE}"
}

ensure_cloudflare_secret() {
  local token
  token="$(read_cloudflare_token)"
  [[ -n "${token}" ]] || die "Cloudflare API token is empty"

  log "Ensure cert-manager Cloudflare token secret..."
  kubectl create ns cert-manager --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl -n cert-manager create secret generic cloudflare-api-token-secret \
    --from-literal=api-token="${token}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

wait_clusterissuer_ready() {
  local name="$1"
  kubectl wait --for=condition=Ready "clusterissuer/${name}" --timeout=300s \
    || die "ClusterIssuer ${name} is not Ready"
}

ensure_cluster_issuers() {
  [[ -f "${CLUSTERISSUER_FILE}" ]] || die "Missing ClusterIssuer manifest: ${CLUSTERISSUER_FILE}"

  log "Apply ClusterIssuers..."
  kubectl apply -f "${CLUSTERISSUER_FILE}"

  wait_clusterissuer_ready letsencrypt-staging
  wait_clusterissuer_ready letsencrypt-prod
}

detect_public_ip() {
  local ip

  ip="$(kubectl -n kube-system get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
  if [[ -n "${ip}" ]]; then
    echo "${ip}"
    return
  fi

  ip="$(kubectl get node -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}' 2>/dev/null || true)"
  if [[ -n "${ip}" ]]; then
    echo "${ip}"
    return
  fi

  ip="$(curl -fsS https://api.ipify.org 2>/dev/null || true)"
  [[ -n "${ip}" ]] || die "Unable to detect public IP"
  echo "${ip}"
}

cf_api_json() {
  local method="$1"
  local endpoint="$2"
  local payload="${3:-}"
  local token

  token="$(read_cloudflare_token)"
  [[ -n "${token}" ]] || die "Cloudflare API token is empty"

  if [[ -n "${payload}" ]]; then
    curl -fsS -X "${method}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      --data "${payload}" \
      "https://api.cloudflare.com/client/v4${endpoint}"
  else
    curl -fsS -X "${method}" \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json" \
      "https://api.cloudflare.com/client/v4${endpoint}"
  fi
}

ensure_wildcard_dns_record() {
  local target_ip zone_resp zone_id records_resp rec_id rec_content rec_proxied payload

  target_ip="$(detect_public_ip)"
  log "Ensure wildcard DNS ${WILDCARD_FQDN} -> ${target_ip}"

  zone_resp="$(curl -fsS --get \
    -H "Authorization: Bearer $(read_cloudflare_token)" \
    -H "Content-Type: application/json" \
    --data-urlencode "name=${BASE_DOMAIN}" \
    --data-urlencode "status=active" \
    "https://api.cloudflare.com/client/v4/zones")"

  zone_id="$(jq -r '.result[0].id // empty' <<<"${zone_resp}")"
  [[ -n "${zone_id}" ]] || die "Cloudflare zone not found for ${BASE_DOMAIN}"

  records_resp="$(curl -fsS --get \
    -H "Authorization: Bearer $(read_cloudflare_token)" \
    -H "Content-Type: application/json" \
    --data-urlencode "type=A" \
    --data-urlencode "name=${WILDCARD_FQDN}" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records")"

  rec_id="$(jq -r '.result[0].id // empty' <<<"${records_resp}")"
  rec_content="$(jq -r '.result[0].content // empty' <<<"${records_resp}")"
  rec_proxied="$(jq -r '.result[0].proxied // false' <<<"${records_resp}")"

  if [[ -n "${rec_id}" && "${rec_content}" == "${target_ip}" && "${rec_proxied}" == "false" ]]; then
    log "Wildcard DNS record already up to date."
    return
  fi

  payload="$(jq -n --arg type "A" --arg name "${WILDCARD_FQDN}" --arg content "${target_ip}" '{type:$type,name:$name,content:$content,ttl:1,proxied:false}')"

  if [[ -n "${rec_id}" ]]; then
    cf_api_json PUT "/zones/${zone_id}/dns_records/${rec_id}" "${payload}" >/dev/null
    log "Wildcard DNS record updated."
  else
    cf_api_json POST "/zones/${zone_id}/dns_records" "${payload}" >/dev/null
    log "Wildcard DNS record created."
  fi
}

ensure_argocd() {
  [[ -x "${ARGO_BOOTSTRAP_SH}" ]] || die "Missing Argo bootstrap script: ${ARGO_BOOTSTRAP_SH}"
  log "Run Argo CD bootstrap..."
  bash "${ARGO_BOOTSTRAP_SH}"
}

need systemctl
ensure_runtime_deps

ensure_k3s_install
need kubectl

# Detect k3s data dir (Hetzner + /srv design)
K3S_DATA_DIR="$(detect_k3s_data_dir)"
MANIFESTS_DIR="${K3S_DATA_DIR}/server/manifests"

log "Using K3S_DATA_DIR=${K3S_DATA_DIR}"
log "Using MANIFESTS_DIR=${MANIFESTS_DIR}"

log "Ensure k3s running..."
systemctl is-active --quiet k3s || systemctl start k3s

log "Node status:"
kubectl get nodes -o wide

log "Ensure /etc/rancher/k3s/k3s.yaml readable (mode 644)..."
chmod 644 /etc/rancher/k3s/k3s.yaml

log "Ensure kubeconfig for user devops..."
[[ -x "${KUBECONFIG_SH}" ]] || die "Missing kubeconfig helper: ${KUBECONFIG_SH}"
"${KUBECONFIG_SH}" devops

log "Apply Traefik HelmChartConfig (LoadBalancer + ServiceLB model)..."
apply_traefik_config
sleep 3

log "Wait for Traefik deployment to exist..."
wait_for_deployment_exists kube-system traefik || die "Traefik deployment was not created in time."

log "Wait for Traefik rollout..."
kubectl -n kube-system rollout status deploy/traefik --timeout=300s
validate_traefik_service_lb

ensure_cert_manager
ensure_cloudflare_secret
ensure_cluster_issuers
ensure_wildcard_dns_record
ensure_argocd

log "CH02 orchestrator done."
