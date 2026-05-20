#!/usr/bin/env bash
set -euo pipefail

ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
log(){ echo "[CH04][$(date -u +%FT%TZ)] $*"; }

json_remove_oidc_config() {
  kubectl -n "${ARGOCD_NAMESPACE}" patch configmap argocd-cm --type=json \
    -p='[{"op":"remove","path":"/data/oidc.config"}]' >/dev/null 2>&1 || true
}

diagnose() {
  log "Collecting Argo CD server baseline diagnostics"
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server -o wide || true
  kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server -o wide || true
}

ready_revision() {
  kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.annotations.deployment\.kubernetes\.io/revision}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk '$2 > 0 && $3 == $2 {print $1}' \
    | sort -n \
    | head -1 || true
}

has_degraded_rollout() {
  local unhealthy_pods=""
  local active_unready_rs=""

  unhealthy_pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
    | awk '$2 != "true" || $3 == "CrashLoopBackOff" {print $1}' || true)"

  active_unready_rs="$(kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk '$2 > 0 && ($3 == "" || $3 < $2) {print $1}' || true)"

  [[ -n "${unhealthy_pods}" || -n "${active_unready_rs}" ]]
}

scale_down_unready_replicasets() {
  local bad_rs=""
  bad_rs="$(kubectl -n "${ARGOCD_NAMESPACE}" get rs -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.replicas}{"\t"}{.status.readyReplicas}{"\n"}{end}' 2>/dev/null \
    | awk '$2 > 0 && ($3 == "" || $3 < $2) {print $1}' || true)"

  while IFS= read -r rs_name; do
    [[ -n "${rs_name}" ]] || continue
    log "Scaling down unhealthy ReplicaSet ${rs_name}"
    kubectl -n "${ARGOCD_NAMESPACE}" scale rs "${rs_name}" --replicas=0 >/dev/null 2>&1 || true
  done <<< "${bad_rs}"
}

delete_unhealthy_pods() {
  local bad_pods=""
  bad_pods="$(kubectl -n "${ARGOCD_NAMESPACE}" get pods -l app.kubernetes.io/name=argocd-server \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.containerStatuses[0].ready}{"\t"}{.status.containerStatuses[0].state.waiting.reason}{"\n"}{end}' 2>/dev/null \
    | awk '$2 != "true" || $3 == "CrashLoopBackOff" {print $1}' || true)"

  while IFS= read -r pod_name; do
    [[ -n "${pod_name}" ]] || continue
    log "Deleting unhealthy pod ${pod_name}"
    kubectl -n "${ARGOCD_NAMESPACE}" delete pod "${pod_name}" --grace-period=0 --force >/dev/null 2>&1 || true
  done <<< "${bad_pods}"
}

main() {
  kubectl -n "${ARGOCD_NAMESPACE}" get deploy/argocd-server >/dev/null 2>&1 || {
    log "argocd-server deployment not found; skipping repair"
    return 0
  }

  if ! has_degraded_rollout && kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=30s >/dev/null 2>&1; then
    log "Argo CD server baseline is clean"
    return 0
  fi

  log "Argo CD server baseline is degraded; removing CH04.6 OIDC config and repairing rollout"
  diagnose || true
  json_remove_oidc_config || true

  local rev=""
  rev="$(ready_revision)"
  if [[ -n "${rev}" ]]; then
    log "Rolling back argocd-server explicitly to ready revision ${rev}"
    kubectl -n "${ARGOCD_NAMESPACE}" rollout undo deploy/argocd-server --to-revision="${rev}" >/dev/null 2>&1 || true
  else
    log "No ready argocd-server revision found; cleanup will only remove unhealthy pods/ReplicaSets"
  fi

  scale_down_unready_replicasets || true
  delete_unhealthy_pods || true

  if kubectl -n "${ARGOCD_NAMESPACE}" rollout status deploy/argocd-server --timeout=180s; then
    log "Argo CD baseline repair completed"
    return 0
  fi

  diagnose || true
  echo "FATAL: Argo CD baseline repair failed; do not run CH04.6 until CH04 is clean" >&2
  return 1
}

main "$@"
