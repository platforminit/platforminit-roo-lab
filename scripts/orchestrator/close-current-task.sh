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

if [[ "$track" != "platform" && "$track" != "n8n" ]]; then
  echo "Usage: $0 --track platform|n8n --task TASK-ID" >&2
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
