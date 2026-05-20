#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ORCH="${SCRIPT_DIR}/ch02-orchestrator.sh"

[[ -x "${ORCH}" ]] || chmod +x "${ORCH}"
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  exec sudo -E bash "${ORCH}" "$@"
fi
exec bash "${ORCH}" "$@"
