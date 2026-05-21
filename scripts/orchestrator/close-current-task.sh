#!/usr/bin/env bash
set -euo pipefail
TRACK=""
TASK_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --track) TRACK="${2:-}"; shift 2 ;;
    --task) TASK_ID="${2:-}"; shift 2 ;;
    *) echo "[error] unknown arg: $1"; exit 2 ;;
  esac
done
if [ -z "$TRACK" ] || [ -z "$TASK_ID" ]; then
  echo "usage: $0 --track platform|n8n --task TASK_ID"
  exit 2
fi
python3 - "$TRACK" "$TASK_ID" <<'PY_TASK_CLOSE'
import json
import sys
from pathlib import Path
from datetime import datetime, timezone
track, task_id = sys.argv[1], sys.argv[2]
path = Path(f"tasks/status/{track}.json")
data = json.loads(path.read_text(encoding="utf-8"))
found = False
for task in data["tasks"]:
    if task["id"] == task_id:
        task["is_completed"] = True
        task["completed_at"] = datetime.now(timezone.utc).isoformat()
        found = True
        break
if not found:
    raise SystemExit(f"[error] task not found: {task_id}")
data["updated_at"] = datetime.now(timezone.utc).isoformat()
path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"[ok] completed {task_id} in {path}")
PY_TASK_CLOSE
python3 scripts/orchestrator/generate-next-task.py --track "$TRACK" --write
