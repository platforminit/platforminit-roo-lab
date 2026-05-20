#!/usr/bin/env bash
set -euo pipefail

REMOTE_TMP="${1:?remote tmp path is required}"
RUNTIME_ROOT_INPUT="${2:-auto}"
AUTOMATION_SSH_PUBLIC_KEY="${3:?automation public key is required}"
COLLECT_DIR="/tmp/platforminit-baseline-collect"
RUNTIME_ROOT=""
AUDIT_DIR=""

collect_artifacts_on_exit() {
  local rc="$1"
  set +e

  rm -rf "$COLLECT_DIR"
  install -d -m 755 "$COLLECT_DIR" "$COLLECT_DIR/reports" "$COLLECT_DIR/audit" "$COLLECT_DIR/diagnostics"

  {
    printf 'exit_status=%s\n' "$rc"
    printf 'runtime_root=%s\n' "${RUNTIME_ROOT:-unresolved}"
    printf 'audit_dir=%s\n' "${AUDIT_DIR:-unresolved}"
    printf 'timestamp=%s\n' "$(date -u +%FT%TZ)"
  } > "$COLLECT_DIR/diagnostics/ch02-remote-context.env"

  if [[ -n "${RUNTIME_ROOT:-}" && -d "${RUNTIME_ROOT}/reports" ]]; then
    cp -a "${RUNTIME_ROOT}/reports/." "$COLLECT_DIR/reports/"
  fi

  if [[ -n "${AUDIT_DIR:-}" && -d "${AUDIT_DIR}" ]]; then
    cp -a "${AUDIT_DIR}/." "$COLLECT_DIR/audit/"
  fi

  find "$COLLECT_DIR" -type d -exec chmod 755 {} +
  find "$COLLECT_DIR" -type f -exec chmod 644 {} +

  exit "$rc"
}
trap 'collect_artifacts_on_exit "$?"' EXIT

load_host_context() {
  if [[ -f /etc/platforminit/host-context.env ]]; then
    # shellcheck disable=SC1091
    source /etc/platforminit/host-context.env
  fi
  PLATFORMINIT_VOLUME_LAYOUT="${PLATFORMINIT_VOLUME_LAYOUT:-single}"
  PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv/data}"
}

assert_volume_layout_ready() {
  local layout="$1"
  case "$layout" in
    none)
      echo "Volume layout is none; using root filesystem backed runtime under /var/lib/platforminit."
      ;;
    single)
      if ! mountpoint -q /srv; then
        echo "FATAL: volume_layout=single requires /srv to be a mounted persistent volume." >&2
        exit 1
      fi
      ;;
    split)
      if ! mountpoint -q "${PLATFORMINIT_DATA_PATH}"; then
        echo "FATAL: volume_layout=split requires ${PLATFORMINIT_DATA_PATH} to be a mounted persistent data volume." >&2
        echo "Hint: run 01.1 Host Bootstrap after 01 Create/Rebuild so attached volumes are formatted and mounted." >&2
        exit 1
      fi
      ;;
    *)
      echo "FATAL: unsupported PLATFORMINIT_VOLUME_LAYOUT=${layout}" >&2
      exit 1
      ;;
  esac
}

resolve_runtime_root() {
  local requested="$1"
  if [[ -n "$requested" && "$requested" != "auto" ]]; then
    printf '%s\n' "$requested"
    return 0
  fi
  case "${PLATFORMINIT_VOLUME_LAYOUT}" in
    none) printf '%s\n' "/var/lib/platforminit/ch01-runtime" ;;
    single) printf '%s\n' "/srv/platforminit/ch01-runtime" ;;
    split) printf '%s\n' "${PLATFORMINIT_DATA_PATH}/platforminit/ch01-runtime" ;;
  esac
}

resolve_audit_dir() {
  case "${PLATFORMINIT_VOLUME_LAYOUT}" in
    none) printf '%s\n' "/var/lib/platforminit/audit" ;;
    single) printf '%s\n' "/srv/platforminit/audit" ;;
    split) printf '%s\n' "${PLATFORMINIT_DATA_PATH}/platforminit/audit" ;;
  esac
}

load_host_context
assert_volume_layout_ready "${PLATFORMINIT_VOLUME_LAYOUT}"
RUNTIME_ROOT="$(resolve_runtime_root "$RUNTIME_ROOT_INPUT")"
AUDIT_DIR="$(resolve_audit_dir)"

install -d -m 755 "$AUDIT_DIR" "$RUNTIME_ROOT" "$RUNTIME_ROOT/reports" "$RUNTIME_ROOT/state" "$RUNTIME_ROOT/work" "$RUNTIME_ROOT/secrets"
printf '%s\n' "$AUTOMATION_SSH_PUBLIC_KEY" > "$RUNTIME_ROOT/secrets/authorized_keys"
chmod 600 "$RUNTIME_ROOT/secrets/authorized_keys"
rm -rf "$REMOTE_TMP"
mkdir -p "$REMOTE_TMP"
tar -xzf "$REMOTE_TMP.tar.gz" -C "$REMOTE_TMP"
find "$REMOTE_TMP/platform/host-baseline" -type f -name "*.sh" -exec chmod +x {} \;
CH01_RUNTIME_ROOT="$RUNTIME_ROOT" PLATFORMINIT_AUDIT_DIR="$AUDIT_DIR" AUTHORIZED_KEYS_FILE="$RUNTIME_ROOT/secrets/authorized_keys" "$REMOTE_TMP/platform/host-baseline/scripts/apply-policy-baseline.sh"
CH01_RUNTIME_ROOT="$RUNTIME_ROOT" PLATFORMINIT_AUDIT_DIR="$AUDIT_DIR" REPORT_DIR="$RUNTIME_ROOT/reports" "$REMOTE_TMP/platform/host-baseline/validate/ch01-validate-host.sh"
