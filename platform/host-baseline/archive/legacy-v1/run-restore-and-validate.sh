#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./ch01-env.sh
source "${SCRIPT_DIR}/ch01-env.sh"

RESTORE_SCRIPT="${RESTORE_SCRIPT:-${CH01_CODE_ROOT}/restore/restore-state-v2.2.sh}"
VALIDATE_SCRIPT="${VALIDATE_SCRIPT:-${CH01_CODE_ROOT}/validate/ch01-validate-host.sh}"

mkdir -p "${REPORT_DIR}"

echo "[INFO] CH01_CODE_ROOT=${CH01_CODE_ROOT}"
echo "[INFO] CH01_RUNTIME_ROOT=${CH01_RUNTIME_ROOT}"
echo "[INFO] Running restore: ${RESTORE_SCRIPT}"
sudo CH01_CODE_ROOT="${CH01_CODE_ROOT}" CH01_RUNTIME_ROOT="${CH01_RUNTIME_ROOT}" REPORT_DIR="${REPORT_DIR}"   STATE_DIR="${STATE_DIR}" SECRETS_DIR="${SECRETS_DIR}" "${RESTORE_SCRIPT}"

if [[ ! -x "${VALIDATE_SCRIPT}" ]]; then
  echo "[WARN] Validator not executable, fixing perms"
  chmod +x "${VALIDATE_SCRIPT}" 2>/dev/null || true
fi

echo "[INFO] Running CH01 validator: ${VALIDATE_SCRIPT}"
sudo CH01_CODE_ROOT="${CH01_CODE_ROOT}" CH01_RUNTIME_ROOT="${CH01_RUNTIME_ROOT}" REPORT_DIR="${REPORT_DIR}"   STATE_DIR="${STATE_DIR}" SECRETS_DIR="${SECRETS_DIR}" "${VALIDATE_SCRIPT}"

json_report="$(ls -1t "${REPORT_DIR}"/validate-host-*.json 2>/dev/null | head -n1)"
md_report="$(ls -1t "${REPORT_DIR}"/validate-host-*.md 2>/dev/null | head -n1)"

if [[ -z "${json_report:-}" || ! -f "${json_report}" ]]; then
  echo "[ERROR] No JSON validation report found"
  exit 2
fi

fail_count="$(jq -r '.summary.fail // 999' "${json_report}")"
warn_count="$(jq -r '.summary.warn // 0' "${json_report}")"
pass_count="$(jq -r '.summary.pass // 0' "${json_report}")"

echo "[INFO] Validation summary: PASS=${pass_count} WARN=${warn_count} FAIL=${fail_count}"
echo "[INFO] JSON report: ${json_report}"
echo "[INFO] MD report:   ${md_report}"

if [[ "${fail_count}" != "0" ]]; then
  echo "[ERROR] CH01 validation failed"
  exit 2
fi

echo "[INFO] CH01 restore + validation passed"
