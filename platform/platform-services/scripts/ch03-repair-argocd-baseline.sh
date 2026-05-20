#!/usr/bin/env bash
set -euo pipefail

log(){ echo "[CH04][ARGOCD-BASELINE][$(date -u +%FT%TZ)] $*"; }

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
export KUBECONFIG

need(){ command -v "$1" >/dev/null 2>&1 || { echo "FATAL: missing binary: $1" >&2; exit 1; }; }
need kubectl

kubectl get ns "${ARGOCD_NAMESPACE}" >/dev/null 2>&1 || { log "Argo CD namespace is not present; skipping baseline repair"; exit 0; }
kubectl -n "${ARGOCD_NAMESPACE}" get deploy/argocd-server >/dev/null 2>&1 || { log "argocd-server deployment is not present; skipping baseline repair"; exit 0; }

argocd_rollout_is_degraded() {
  local bad_pods=""
  local bad_rs=""
  local progress_state=""

  progress_state="$(kubectl -n "${ARGOCD_NAMESPACE}" get deploy argocd-server \
    -o jsonpath='{.status.conditions[?(@.type=="Progressing")].reason}' 2>/dev/null || true)"

  bad_pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
    | awk '$2 != "true" || $3 == "CrashLoopBackOff" {print $1}' || true)"

  bad_rs="$(kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk '$2 > 0 && ($3 == "" || $3 < $2) {print $1}' || true)"

  [[ "${progress_state}" == "ProgressDeadlineExceeded" || -n "${bad_pods}" || -n "${bad_rs}" ]]
}

collect_diagnostics() {
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server -o wide || true
}

ready_server_revision() {
  local ready_pod=""
  local owner_rs=""
  ready_pod="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
    | awk '$2 == "true" {print $1; exit}' || true)"
  [[ -n "${ready_pod}" ]] || return 1

  owner_rs="$(kubectl -n "${ARGOCD_NAMESPACE}" get pod "${ready_pod}" \
    -o jsonpath='{.metadata.ownerReferences[0].name}' 2>/dev/null || true)"
  [[ -n "${owner_rs}" ]] || return 1

  kubectl -n "${ARGOCD_NAMESPACE}" get rs "${owner_rs}" \
    -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}' 2>/dev/null
}

remove_managed_sso_config() {
  log "Removing CH04.6-managed Argo CD OIDC config from argocd-cm"
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=json \
    -p='[{"op":"remove","path":"/data/oidc.config"}]' >/dev/null 2>&1 || true
}

rollback_to_ready_revision() {
  local revision=""
  revision="$(ready_server_revision || true)"
  if [[ -z "${revision}" ]]; then
    log "No ready argocd-server pod revision found; cannot perform explicit rollback"
    return 1
  fi

  log "Rolling argocd-server deployment back to currently ready revision ${revision}"
  kubectl -n "${ARGOCD_NAMESPACE}" rollout undo deploy/argocd-server --to-revision="${revision}" >/dev/null || return 1
}

cleanup_unhealthy_objects() {
  local bad_pods=""
  local bad_rs=""

  bad_rs="$(kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk '$2 > 0 && ($3 == "" || $3 < $2) {print $1}' || true)"
  while IFS= read -r rs_name; do
    [[ -n "${rs_name}" ]] || continue
    log "Scaling down unhealthy ReplicaSet ${rs_name}"
    kubectl -n "${ARGOCD_NAMESPACE}" scale rs "${rs_name}" --replicas=0 >/dev/null 2>&1 || true
  done <<< "${bad_rs}"

  bad_pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
    | awk '$2 != "true" || $3 == "CrashLoopBackOff" {print $1}' || true)"
  while IFS= read -r pod_name; do
    [[ -n "${pod_name}" ]] || continue
    log "Deleting unhealthy pod ${pod_name}"
    kubectl -n "${ARGOCD_NAMESPACE}" delete pod "${pod_name}" --grace-period=0 --force >/dev/null 2>&1 || true
  done <<< "${bad_pods}"
}

has_ready_server_pod() {
  kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
    | grep -qx 'true'
}

if ! argocd_rollout_is_degraded; then
  log "Argo CD server baseline is healthy; no repair needed"
  exit 0
fi

log "Detected degraded Argo CD server rollout; repairing baseline before platform/SSO operations"
collect_diagnostics
remove_managed_sso_config
rollback_to_ready_revision || true
cleanup_unhealthy_objects

if kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=120s >/dev/null 2>&1; then
  log "Argo CD server deployment recovered"
  exit 0
fi

if has_ready_server_pod; then
  log "Argo CD deployment status is still noisy, but a ready server pod is available after cleanup"
  collect_diagnostics
  exit 0
fi

collect_diagnostics
 echo "FATAL: Argo CD server baseline repair failed" >&2
exit 1
