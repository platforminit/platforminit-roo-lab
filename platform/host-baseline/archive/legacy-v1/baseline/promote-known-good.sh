#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CODE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=/dev/null
source "$CODE_ROOT/scripts/ch01-env.sh"

SRC="${1:-$STATE_DIR/state-current.json}"
DST="${2:-$CODE_ROOT/baseline/state-known-good.json}"

[ -f "$SRC" ] || { echo "Missing current state: $SRC"; exit 1; }
cp -f "$SRC" "$DST"
echo "Promoted -> $DST"
