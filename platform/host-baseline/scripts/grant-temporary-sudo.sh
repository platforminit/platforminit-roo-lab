#!/usr/bin/env bash
set -euo pipefail
source "${PLATFORMINIT_LIB_POLICY:-/usr/local/lib/platforminit/lib-policy.sh}"
USER_NAME="${1:-devops}"
WINDOW_MINUTES="${2:-15}"
SCOPE="${3:-baseline}"
RUN_ID="${4:-manual}"
SAFE_RUN_ID="$(printf '%s' "$RUN_ID" | tr -cd '[:alnum:]_.-')"
[[ -n "$SAFE_RUN_ID" ]] || SAFE_RUN_ID="manual"
SUDO_FILE="/etc/sudoers.d/${USER_NAME}-temporary"

scope_sudoers_content() {
  case "$1" in
    baseline)
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/ch02-remote.sh *
' "$USER_NAME"
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/apply-baseline-remote.sh *
' "$USER_NAME"
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/collect-baseline-artifacts.sh *
' "$USER_NAME"
      ;;
    drift)
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/drift-check.sh
' "$USER_NAME"
      ;;
    security-check)
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/security-os-check.sh *
' "$USER_NAME"
      ;;
    security-apply)
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/security-os-apply.sh
' "$USER_NAME"
      ;;
    fim-check)
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/fim-check.sh *
' "$USER_NAME"
      ;;
    aide-init)
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/aide-init.sh *
' "$USER_NAME"
      ;;
    aide-check)
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/aide-check.sh *
' "$USER_NAME"
      ;;
    cluster)
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/ch03-remote.sh *
' "$USER_NAME"
      ;;
    platform)
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/ch04-remote.sh *
' "$USER_NAME"
      ;;
    observability)
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/ch05-remote.sh *
' "$USER_NAME"
      ;;
    identity)
      # Compatibility scope for existing CH04.6 Argo CD SSO workflows.
      # Older hosts know this scope as the former CH06 identity entrypoint; keep
      # both command paths valid during the CH04.6 rename window.
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/ch06-remote.sh *
' "$USER_NAME"
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/ch04-6-remote.sh *
' "$USER_NAME"
      ;;
    identity-foundation)
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/ch04-5-remote.sh *
' "$USER_NAME"
      ;;
    identity-sso)
      # New semantic alias for CH04.6. Keep ch06-remote.sh until all live hosts
      # have refreshed grant tooling from the host baseline.
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/ch04-6-remote.sh *
' "$USER_NAME"
      printf '%s ALL=(root) NOPASSWD: /tmp/platforminit-run/ch06-remote.sh *
' "$USER_NAME"
      ;;
    interactive-elevation)
      printf '%s ALL=(ALL) NOPASSWD:ALL
' "$USER_NAME"
      ;;
    automation-admin-shell)
      printf '%s ALL=(root) NOPASSWD: /bin/su - itadmin, /usr/bin/su - itadmin
' "$USER_NAME"
      ;;
    *)
      echo "Unsupported scope: $1" >&2
      exit 1
      ;;
  esac
}

scope_sudoers_content "$SCOPE" > "$SUDO_FILE"
chmod 440 "$SUDO_FILE"
visudo -cf "$SUDO_FILE" >/dev/null

if [[ "$SCOPE" == "interactive-elevation" ]]; then
  if ! command -v runuser >/dev/null 2>&1; then
    echo "FATAL: runuser is required to verify interactive elevation" >&2
    rm -f "$SUDO_FILE"
    exit 1
  fi
  if ! runuser -u "$USER_NAME" -- sudo -n true; then
    echo "FATAL: interactive sudo verification failed for ${USER_NAME}; refusing false-positive A1 success" >&2
    rm -f "$SUDO_FILE"
    exit 1
  fi
fi

printf 'temporary sudo granted: user=%s scope=%s duration=%sm sudoers=%s\n' "$USER_NAME" "$SCOPE" "$WINDOW_MINUTES" "$SUDO_FILE"

audit_event "temporary_sudo_granted" "ok" "user=${USER_NAME} scope=${SCOPE} duration=${WINDOW_MINUTES}m run_id=${RUN_ID}"

cleanup_cmd=$(cat <<EOF
sleep $((WINDOW_MINUTES * 60))
rm -f '$SUDO_FILE'
if [[ -f '${PLATFORMINIT_AUDIT_DIR}/security.log' ]]; then
  printf '{"ts":"%s","event":"%s","status":"%s","detail":"%s"}\n'     "$(date -u +%FT%TZ)"     "temporary_sudo_revoked"     "ok"     "user=${USER_NAME} scope=${SCOPE} duration=${WINDOW_MINUTES}m run_id=${RUN_ID}" >> '${PLATFORMINIT_AUDIT_DIR}/security.log'
fi
EOF
)
nohup bash -lc "$cleanup_cmd" >/dev/null 2>&1 &
