#!/usr/bin/env bash
set -euo pipefail

PLATFORMINIT_AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-/srv/platforminit/audit}"
mkdir -p "$PLATFORMINIT_AUDIT_DIR"

# NOTE: PLATFORMINIT_BASELINE_PROFILE is NOT defaulted here.
# The resolve_baseline_profile() function below handles the full resolution chain:
#   1. PLATFORMINIT_BASELINE_PROFILE env var (if set by caller)
#   2. /etc/platforminit/host-context.env (if file exists and env var is unset)
#   3. Default to platform-k3s (only after host-context lookup)
# Defaulting at library source time would pre-empt the host-context.env lookup.

json_escape() {
  local s=${1:-}
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

audit_event() {
  local event="$1"
  local status="${2:-ok}"
  local detail="${3:-}"
  printf '{"ts":"%s","event":"%s","status":"%s","detail":"%s"}\n' \
    "$(date -u +%FT%TZ)" \
    "$(json_escape "$event")" \
    "$(json_escape "$status")" \
    "$(json_escape "$detail")" >> "$PLATFORMINIT_AUDIT_DIR/security.log"
}

baseline_event() {
  local action="$1"
  local status="${2:-ok}"
  local detail="${3:-}"
  printf '{"ts":"%s","action":"%s","status":"%s","detail":"%s"}\n' \
    "$(date -u +%FT%TZ)" \
    "$(json_escape "$action")" \
    "$(json_escape "$status")" \
    "$(json_escape "$detail")" >> "$PLATFORMINIT_AUDIT_DIR/ch02-baseline.log"
}

# Resolve the active baseline profile.
# Checks PLATFORMINIT_BASELINE_PROFILE env var, then /etc/platforminit/host-context.env,
# then falls back to the default (platform-k3s).
resolve_baseline_profile() {
  local profile="${PLATFORMINIT_BASELINE_PROFILE:-}"
  if [[ -n "$profile" ]]; then
    printf '%s\n' "$profile"
    return 0
  fi
  if [[ -f /etc/platforminit/host-context.env ]]; then
    # shellcheck disable=SC1091
    source /etc/platforminit/host-context.env
    profile="${PLATFORMINIT_BASELINE_PROFILE:-}"
  fi
  printf '%s\n' "${profile:-platform-k3s}"
}

# Validate that the profile is one of the known profiles.
validate_baseline_profile() {
  local profile="$1"
  case "$profile" in
    platform-k3s|standalone-n8n)
      return 0
      ;;
    *)
      echo "FATAL: unknown baseline profile '${profile}'. Valid profiles: platform-k3s, standalone-n8n" >&2
      exit 1
      ;;
  esac
}
