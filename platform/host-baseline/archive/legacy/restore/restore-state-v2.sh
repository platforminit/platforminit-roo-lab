#!/usr/bin/env bash
set -euo pipefail
# Wrapper for the current restore implementation
exec "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/restore-state-v2.2.sh" "$@"
