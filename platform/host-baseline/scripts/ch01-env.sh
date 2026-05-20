#!/usr/bin/env bash
# shellcheck shell=bash

if [[ -n "${CH01_ENV_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
export CH01_ENV_LOADED=1

if [[ -n "${BASH_SOURCE[0]:-}" ]]; then
  _CH01_ENV_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  export CH01_CODE_ROOT="${CH01_CODE_ROOT:-$(cd -- "${_CH01_ENV_DIR}/.." && pwd)}"
else
  export CH01_CODE_ROOT="${CH01_CODE_ROOT:-$PWD}"
fi

export CH01_RUNTIME_ROOT="${CH01_RUNTIME_ROOT:-/srv/ch01-runtime}"
export REPORT_DIR="${REPORT_DIR:-${CH01_RUNTIME_ROOT}/reports}"
export STATE_DIR="${STATE_DIR:-${CH01_RUNTIME_ROOT}/state}"
export WORK_DIR="${WORK_DIR:-${CH01_RUNTIME_ROOT}/work}"
export SECRETS_DIR="${SECRETS_DIR:-${CH01_RUNTIME_ROOT}/secrets}"

mkdir -p "${REPORT_DIR}" "${STATE_DIR}" "${WORK_DIR}"
