#!/usr/bin/env bash
set -euo pipefail

track=""
task=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --track) track="${2:-}"; shift 2 ;;
    --task) task="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

usage() {
  echo "Usage: $0 --track platform --task TASK-ID" >&2
  echo "PlatformInit orchestration is PlatformInit-only: 'platform' is the only supported track." >&2
}

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
if [[ -z "$task" ]]; then
  echo "--task is required" >&2
  exit 2
fi

root="$(git rev-parse --show-toplevel)"
cd "$root"

python3 tools/task_controller/taskctl.py complete "$task" --actor platforminit-release-manager
python3 tools/task_controller/taskctl.py validate
python3 tools/task_controller/taskctl.py next --track "$track"
