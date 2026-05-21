#!/usr/bin/env bash
set -euo pipefail
TRACK="platform"
while [ $# -gt 0 ]; do
  case "$1" in
    --track) TRACK="${2:-}"; shift 2 ;;
    *) echo "[error] unknown arg: $1"; exit 2 ;;
  esac
done
if [ "$TRACK" != "platform" ] && [ "$TRACK" != "n8n" ]; then
  echo "[error] track must be platform or n8n"
  exit 2
fi
cd /mnt/d/SYSADMIN/platforminit-roo-lab
./scripts/lib/require-wsl-runtime.sh >/dev/null
if [ -n "$(git status --short)" ]; then
  echo "[error] working tree is not clean"
  git status --short
  exit 1
fi
python3 scripts/orchestrator/generate-next-task.py --track "$TRACK" --write
BRANCH="$(python3 scripts/orchestrator/generate-next-task.py --track "$TRACK" --print-branch)"
if [ -z "$BRANCH" ]; then
  echo "[ok] no remaining tasks for track: $TRACK"
  exit 0
fi
CURRENT="$(git branch --show-current)"
if [ "$CURRENT" = "$BRANCH" ]; then
  echo "[ok] already on branch: $BRANCH"
else
  if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
    git switch "$BRANCH"
  else
    git switch -c "$BRANCH"
  fi
fi
git push -u origin "$BRANCH" >/dev/null 2>&1 || true
echo "[ok] active track: $TRACK"
echo "[ok] active branch: $BRANCH"
echo "[ok] next task: tasks/active/$TRACK/NEXT_TASK.md"
