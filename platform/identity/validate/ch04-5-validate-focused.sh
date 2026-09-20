#!/usr/bin/env bash
set -euo pipefail

#############################################################################
# CH04.5 - Focused validation entrypoint
#
# Task: P-CH04.5-T05 (focused CH04.5 validation and recovery checkpoint)
# Recovery/break-glass statement:
#   platform/identity/docs/ch04-5-identity-recovery-and-break-glass.md
#
# One focused entrypoint for the CH04.5 identity foundation, in two modes:
#
#   static  (default) repository contract only, no cluster access:
#           1. identity model contract
#              - groups/technical users schema, ownership, uniqueness, policy
#              - provider template determinism
#              - reconciler determinism and idempotence
#              - consumer/document taxonomy consistency
#           2. Authentik ingress/TLS contract
#              - single TLS ownership, hostname/Certificate/Ingress agreement
#              - decoupled identity bootstrap
#           3. cross-consumer identity agreement (CH04.6 Argo CD + CH05 Checkmk)
#              - the desired identity model agrees with both active consumers
#              - retired active identities are rejected
#
#   runtime (opt-in, read-only) additionally verifies the expected runtime
#           health signals of the deployed CH04.5 identity foundation:
#             4. Authentik core runtime health (namespace ownership, rollout,
#                image pinning, ingress/TLS material, bootstrap secret presence)
#             5. runtime identity model consistency (group set, membership,
#                break-glass membership) against the repository model
#
# Focused by construction: the step inventory is a closed allowlist of CH04.5
# validators plus the CH05 Checkmk consumer contract validator. An unknown
# argument, an unknown step name or a validator outside this directory is
# refused, so the entrypoint never triggers repository-wide or other-chapter
# validation. The runtime mode performs no mutation: it only reads cluster state.
#############################################################################

VALIDATOR_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${VALIDATOR_DIR}/../../.." && pwd)"
KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
IDENTITY_NAMESPACE="${IDENTITY_NAMESPACE:-identity}"

log()  { echo "[$(date -u +%FT%TZ)] [CH04.5-focused] $*"; }
warn() { echo "[$(date -u +%FT%TZ)] [CH04.5-focused][WARN] $*" >&2; }
die()  { echo "[$(date -u +%FT%TZ)] [CH04.5-focused][FAIL] $*" >&2; exit 1; }

# Closed focused step inventory: "<validator script>|<label>".
STATIC_STEPS=(
  "ch04-5-validate-identity-model-contract.sh|CH04.5 repository identity model contract"
  "ch04-5-validate-authentik-ingress-tls.sh|CH04.5 repository Authentik ingress/TLS contract"
  "ch04-5-validate-identity-cross-consumer.sh|CH04.5 cross-consumer identity agreement (CH04.6 Argo CD + CH05 Checkmk)"
)
RUNTIME_STEPS=(
  "ch04-5-validate-authentik-core.sh|CH04.5 Authentik core runtime health signals"
  "ch04-5-validate-identity-model.sh|CH04.5 runtime identity model consistency"
)

# Expected runtime health signals, in operator language. They are asserted by the
# runtime steps above; this list is the readable contract of what "healthy CH04.5"
# means and is printed before any runtime assertion runs.
RUNTIME_HEALTH_SIGNALS=(
  "identity namespace exists and is owned by platforminit"
  "authentik-server deployment rollout is healthy (all replicas ready)"
  "authentik-server image is pinned (no floating 'latest' tag)"
  "Authentik ingress host auth.<BASE_DOMAIN> resolves to the identity service"
  "the certificate-minted TLS secret authentik-tls is present in the identity namespace"
  "the Authentik bootstrap API token is valid, so the API and break-glass path work"
  "runtime Authentik groups and memberships match the CH04.5 identity model (upsert-no-prune)"
)

FOCUSED_ALLOWLIST=(
  "ch04-5-validate-identity-model-contract.sh"
  "ch04-5-validate-authentik-ingress-tls.sh"
  "ch04-5-validate-identity-cross-consumer.sh"
  "ch04-5-validate-authentik-core.sh"
  "ch04-5-validate-identity-model.sh"
)

usage() {
  cat <<'USAGE'
Focused CH04.5 identity foundation validation.

Usage:
  bash platform/identity/validate/ch04-5-validate-focused.sh [--static|--runtime|--list]

Modes:
  --static   (default) repository contract checks only; no cluster access.
  --runtime  additionally verifies the read-only runtime health signals.
  --list     print the focused step inventory and exit without executing anything.

Environment:
  CH04_5_VALIDATE_MODE=static|runtime   same as --static / --runtime
  KUBECONFIG                            kubeconfig used by --runtime (read-only)
  IDENTITY_NAMESPACE                    identity namespace (default: identity)
USAGE
}

LIST_ONLY=false
MODE="${CH04_5_VALIDATE_MODE:-static}"

while (( $# )); do
  case "$1" in
    --list)    LIST_ONLY=true ;;
    --static)  MODE="static" ;;
    --runtime) MODE="runtime" ;;
    -h|--help) usage; exit 0 ;;
    *)         die "Unsupported argument: $1. This entrypoint runs only the focused CH04.5 steps (--static, --runtime, --list)." ;;
  esac
  shift
done

case "${MODE}" in
  static|runtime) ;;
  *) die "Unsupported CH04_5_VALIDATE_MODE=${MODE}; expected 'static' or 'runtime'" ;;
esac

print_plan() {
  local mode="$1" entry
  log "Focused CH04.5 validation plan (mode=${mode})"
  for entry in "${STATIC_STEPS[@]}"; do
    log "  [static]  ${entry#*|} -> ${entry%%|*}"
  done
  if [[ "${mode}" == "runtime" ]]; then
    log "Expected runtime health signals:"
    local signal
    for signal in "${RUNTIME_HEALTH_SIGNALS[@]}"; do
      log "  [signal]  ${signal}"
    done
    for entry in "${RUNTIME_STEPS[@]}"; do
      log "  [runtime] ${entry#*|} -> ${entry%%|*}"
    done
  else
    log "Runtime health signals are not asserted in static mode; re-run with --runtime for those checks."
  fi
  log "Focused scope: no repository-wide and no other-chapter validation is executed."
}

# Refuse anything that is not a declared CH04.5 focused validator. This keeps the
# entrypoint focused even if the distribution later grows a broader validator.
assert_focused_script() {
  local name="$1" allowed
  [[ "${name}" != */* ]] || die "Refusing non-focused step reference: ${name}"
  for allowed in "${FOCUSED_ALLOWLIST[@]}"; do
    [[ "${name}" == "${allowed}" ]] && return 0
  done
  die "Refusing to run ${name}: it is not a declared focused CH04.5 validator"
}

run_step() {
  local entry="$1" name label path
  name="${entry%%|*}"
  label="${entry#*|}"
  assert_focused_script "${name}"
  path="${VALIDATOR_DIR}/${name}"
  [[ -f "${path}" ]] || die "Missing focused validator: ${path}"

  log "STEP: ${label} (${name})"
  if bash "${path}"; then
    log "STEP PASS: ${label}"
    return 0
  fi
  warn "STEP FAIL: ${label} (${name})"
  return 1
}

assert_runtime_access() {
  command -v kubectl >/dev/null 2>&1 \
    || die "Runtime validation needs kubectl. Re-run with --static for repository-only validation."
  [[ -f "${KUBECONFIG}" ]] \
    || die "Runtime validation needs the kubeconfig ${KUBECONFIG}. Re-run with --static for repository-only validation."
  kubectl --kubeconfig "${KUBECONFIG}" get nodes >/dev/null 2>&1 \
    || die "Runtime validation needs read access to the cluster via ${KUBECONFIG}. Re-run with --static for repository-only validation."
  kubectl --kubeconfig "${KUBECONFIG}" get ns "${IDENTITY_NAMESPACE}" >/dev/null 2>&1 \
    || die "Missing namespace ${IDENTITY_NAMESPACE}; deploy '04.5 - Deploy Identity Foundation' first, then re-run --runtime."
}

if [[ "${LIST_ONLY}" == "true" ]]; then
  print_plan "${MODE}"
  log "Listing only; no validator was executed."
  exit 0
fi

print_plan "${MODE}"

PASSED=0
FAILED=0
FAILED_LABELS=()
EXECUTED=()

run_and_count() {
  local entry="$1"
  EXECUTED+=("${entry%%|*}")
  if run_step "${entry}"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_LABELS+=("${entry%%|*}")
  fi
}

for entry in "${STATIC_STEPS[@]}"; do
  run_and_count "${entry}"
done

if [[ "${MODE}" == "runtime" ]]; then
  assert_runtime_access
  for entry in "${RUNTIME_STEPS[@]}"; do
    run_and_count "${entry}"
  done
fi

log "Executed focused validators: ${EXECUTED[*]}"
log "Focused CH04.5 validation summary: mode=${MODE} passed=${PASSED} failed=${FAILED}"

if (( FAILED > 0 )); then
  die "Focused CH04.5 validation failed: ${FAILED_LABELS[*]}"
fi

log "PASS: focused CH04.5 validation is clean (mode=${MODE}); see platform/identity/docs/ch04-5-identity-recovery-and-break-glass.md for the recovery checkpoint"
