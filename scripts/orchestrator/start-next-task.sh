#!/usr/bin/env bash
set -euo pipefail

track=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --track) track="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "$track" != "platform" && "$track" != "n8n" ]]; then
  echo "Usage: $0 --track platform|n8n" >&2
  exit 2
fi

root="$(git rev-parse --show-toplevel)"
cd "$root"

branch="$(python3 tools/task_controller/taskctl.py branch --track "$track")"
current="$(git branch --show-current)"
if [[ "$current" != "$branch" ]]; then
  if git show-ref --verify --quiet "refs/heads/$branch"; then
    git switch "$branch"
  else
    git switch -c "$branch" dev
  fi
fi

python3 tools/task_controller/taskctl.py next --track "$track"
echo "Start the displayed task with the controller command shown in the generated view."
