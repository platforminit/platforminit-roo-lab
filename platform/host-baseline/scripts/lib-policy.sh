#!/usr/bin/env bash
set -euo pipefail

PLATFORMINIT_AUDIT_DIR="${PLATFORMINIT_AUDIT_DIR:-/srv/platforminit/audit}"
mkdir -p "$PLATFORMINIT_AUDIT_DIR"

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
