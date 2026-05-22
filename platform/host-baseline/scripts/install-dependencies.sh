#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
YQ_VERSION="v4.44.3"
YQ_SHA256_X86_64="${YQ_SHA256_X86_64:-SKIP}"
YQ_SHA256_AARCH64="${YQ_SHA256_AARCH64:-SKIP}"

resolve_existing_file() {
  local explicit="${1:-}"
  shift || true
  if [[ -n "$explicit" && -f "$explicit" ]]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  local candidate
  for candidate in "$@"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

DEPENDENCY_FILE="$(resolve_existing_file "${DEPENDENCY_FILE:-}"   "$SCRIPT_DIR/dependencies.yaml"   "$SCRIPT_DIR/../policy/dependencies.yaml")" || {
  echo "Missing dependencies.yaml" >&2
  exit 1
}

LIB_POLICY_FILE="$(resolve_existing_file "${PLATFORMINIT_LIB_POLICY:-}"   "$SCRIPT_DIR/lib-policy.sh"   "/usr/local/lib/platforminit/lib-policy.sh")" || {
  echo "Missing lib-policy.sh" >&2
  exit 1
}
source "$LIB_POLICY_FILE"

# Resolve and validate the active baseline profile
BASELINE_PROFILE="$(resolve_baseline_profile)"
validate_baseline_profile "$BASELINE_PROFILE"

install_yq() {
  local arch asset url tmp expected_sha current
  arch="$(uname -m)"
  case "$arch" in
    x86_64) asset="yq_linux_amd64"; expected_sha="$YQ_SHA256_X86_64" ;;
    aarch64|arm64) asset="yq_linux_arm64"; expected_sha="$YQ_SHA256_AARCH64" ;;
    *) echo "Unsupported architecture for yq: $arch" >&2; exit 1 ;;
  esac

  if command -v yq >/dev/null 2>&1; then
    current="$(yq --version 2>/dev/null || true)"
    if grep -q "$YQ_VERSION" <<<"$current"; then
      baseline_event "dependency_external_install" "ok" "yq already present $current profile=${BASELINE_PROFILE}"
      return
    fi
  fi

  url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${asset}"
  tmp="$(mktemp)"
  curl -fsSL -o "$tmp" "$url"
  if [[ "$expected_sha" != "SKIP" ]]; then
    echo "$expected_sha  $tmp" | sha256sum -c -
  fi
  install -m 0755 "$tmp" /usr/local/bin/yq
  rm -f "$tmp"
  baseline_event "dependency_external_install" "ok" "yq ${YQ_VERSION} ${arch} profile=${BASELINE_PROFILE}"
}

apt_install() {
  # Shared packages
  mapfile -t pkgs < <(yq -r '.shared.apt.common[] , .shared.apt.security[]' "$DEPENDENCY_FILE")
  # Profile-specific extra packages
  mapfile -t extra_pkgs < <(yq -r ".profiles.${BASELINE_PROFILE}.apt_extra[]?" "$DEPENDENCY_FILE")
  pkgs+=("${extra_pkgs[@]}")
  if (( ${#pkgs[@]} == 0 )); then
    echo "No apt packages resolved from $DEPENDENCY_FILE" >&2
    exit 1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  baseline_event "dependency_apt_install" "ok" "$(printf '%s ' "${pkgs[@]}") profile=${BASELINE_PROFILE}"
}

main() {
  install_yq
  apt_install
}

main "$@"
