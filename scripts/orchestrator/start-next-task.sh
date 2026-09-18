#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 --track platform" >&2
  echo "PlatformInit orchestration is PlatformInit-only: 'platform' is the only supported track." >&2
}

track=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --track) track="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "$track" == "n8n" ]]; then
  echo "ERROR: --track n8n is not an active PlatformInit track." >&2
  echo "n8n has its own roadmap and task registry and is not selectable through the PlatformInit next-task flow." >&2
  exit 2
fi

if [[ "$track" != "platform" ]]; then
  echo "ERROR: unsupported track '${track:-<none>}'." >&2
  usage
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
