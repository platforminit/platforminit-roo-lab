#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Determine the policy file to use. Prefer an explicit POLICY_FILE environment
# variable when provided and pointing at a readable file. Otherwise look for
# baseline.yaml in the same directory as this script or the conventional
# ../policy location. Exit early if no baseline policy file can be found.
if [[ -n "${POLICY_FILE:-}" && -f "${POLICY_FILE}" ]]; then
  POLICY="${POLICY_FILE}"
elif [[ -f "$SCRIPT_DIR/baseline.yaml" ]]; then
  POLICY="$SCRIPT_DIR/baseline.yaml"
elif [[ -f "$SCRIPT_DIR/../policy/baseline.yaml" ]]; then
  POLICY="$SCRIPT_DIR/../policy/baseline.yaml"
else
  echo "DRIFT | POLICY_FILE_MISSING | baseline.yaml not found" >&2
  exit 1
fi

# Locate and source the lib-policy helper. First honour the
# PLATFORMINIT_LIB_POLICY environment variable when it points to a file.
# Otherwise fall back to a lib-policy.sh co-located with this script if
# present, and finally default to the system-wide installation.
if [[ -n "${PLATFORMINIT_LIB_POLICY:-}" && -f "${PLATFORMINIT_LIB_POLICY}" ]]; then
  LIB_POLICY="${PLATFORMINIT_LIB_POLICY}"
elif [[ -f "$SCRIPT_DIR/lib-policy.sh" ]]; then
  LIB_POLICY="$SCRIPT_DIR/lib-policy.sh"
else
  LIB_POLICY="/usr/local/lib/platforminit/lib-policy.sh"
fi

source "$LIB_POLICY"

# Verify required dependencies are present before proceeding. 'yq' is used to
# parse YAML; fail early with a clear message if it's missing.
command -v yq >/dev/null 2>&1 || { echo "DRIFT | MISSING_DEPENDENCY | yq"; exit 1; }

# Track whether any drift has been detected during evaluation. A non-zero
# status will be returned if drift is found.
drift=0

# Check that all packages defined in the baseline are present on the host. The
# policy may define packages under both .packages.common and .packages.security.
while IFS= read -r pkg; do
  [[ -n "$pkg" ]] || continue
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    echo "DRIFT | PACKAGE_MISSING | $pkg"
    drift=1
  fi
done < <(yq -r '.packages.common[] , .packages.security[]' "$POLICY")

# Validate SSH configuration: root login must be disabled. Report drift if not.
actual_root="$(sshd -T | awk '/^permitrootlogin /{print $2}')"
[[ "$actual_root" == "no" ]] || { echo "DRIFT | SSH_ROOT_LOGIN | $actual_root"; drift=1; }


# Validate PlatformInit volume layout and required mount points.
if [[ -f /etc/platforminit/host-context.env ]]; then
  # shellcheck disable=SC1091
  source /etc/platforminit/host-context.env
fi
PLATFORMINIT_VOLUME_LAYOUT="${PLATFORMINIT_VOLUME_LAYOUT:-single}"
PLATFORMINIT_SRV_PATH="${PLATFORMINIT_SRV_PATH:-/srv}"
PLATFORMINIT_DATA_PATH="${PLATFORMINIT_DATA_PATH:-/srv/data}"
PLATFORMINIT_DB_PATH="${PLATFORMINIT_DB_PATH:-/srv/db}"
PLATFORMINIT_OBSERVABILITY_PATH="${PLATFORMINIT_OBSERVABILITY_PATH:-/srv/observability}"

check_mount_rw() {
  local label="$1" path="$2"
  if ! mountpoint -q "$path"; then
    echo "DRIFT | ${label}_MOUNT | missing:${path}"
    drift=1
    return
  fi
  if ! test -w "$path"; then
    echo "DRIFT | ${label}_WRITE | not-writable:${path}"
    drift=1
  fi
}

case "$PLATFORMINIT_VOLUME_LAYOUT" in
  none)
    test -d "$PLATFORMINIT_SRV_PATH" || { echo "DRIFT | SRV_PATH | missing:${PLATFORMINIT_SRV_PATH}"; drift=1; }
    ;;
  single)
    check_mount_rw SRV "$PLATFORMINIT_SRV_PATH"
    ;;
  split)
    check_mount_rw DATA "$PLATFORMINIT_DATA_PATH"
    check_mount_rw DB "$PLATFORMINIT_DB_PATH"
    check_mount_rw OBSERVABILITY "$PLATFORMINIT_OBSERVABILITY_PATH"
    ;;
  *)
    echo "DRIFT | VOLUME_LAYOUT | unsupported:${PLATFORMINIT_VOLUME_LAYOUT}"
    drift=1
    ;;
esac

# Emit a PASS or DRIFT event and return an appropriate exit code for pipeline consumption.
if (( drift == 0 )); then
  echo "PASS | DRIFT_CHECK | no drift detected"
  baseline_event "drift_check" "ok" "no drift"
else
  baseline_event "drift_check" "drift" "drift detected"
fi
exit $drift
