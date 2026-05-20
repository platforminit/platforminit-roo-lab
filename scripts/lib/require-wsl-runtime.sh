#!/usr/bin/env bash
set -euo pipefail

EXPECTED_ROOT="/mnt/d/SYSADMIN/platforminit-roo-lab"
EXPECTED_USER="hattila"

if ! grep -Eiq "microsoft|wsl" /proc/version; then
  echo "[error] not running inside WSL"
  exit 1
fi

if [ "$(id -un)" != "$EXPECTED_USER" ]; then
  echo "[error] wrong user: expected=$EXPECTED_USER current=$(id -un)"
  exit 1
fi

if [ ! -d "$EXPECTED_ROOT" ]; then
  echo "[error] repository root unavailable: $EXPECTED_ROOT"
  exit 1
fi

cd "$EXPECTED_ROOT"

echo "[ok] WSL runtime guard passed"
