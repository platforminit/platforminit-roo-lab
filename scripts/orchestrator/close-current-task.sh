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
import tempfile
import os
from pathlib import Path
from datetime import datetime, timezone

track, task_id = sys.argv[1], sys.argv[2]

# --- load both status and roadmap ---
status_path = Path(f"tasks/status/{track}.json")
roadmap_path = Path(f"tasks/roadmap/{track}.json")

status_data = json.loads(status_path.read_text(encoding="utf-8"))
roadmap_data = json.loads(roadmap_path.read_text(encoding="utf-8"))

# --- mark task completed in status ---
found = False
for task in status_data["tasks"]:
    if task["id"] == task_id:
        task["status"] = "completed"
        task["completed_at"] = datetime.now(timezone.utc).isoformat()
        found = True
        break
if not found:
    raise SystemExit(f"[error] task not found in status: {task_id}")

# --- mark task completed in roadmap ---
found_roadmap = False
for task in roadmap_data["tasks"]:
    if task["id"] == task_id:
        task["status"] = "completed"
        found_roadmap = True
        break
if not found_roadmap:
    raise SystemExit(f"[error] task not found in roadmap: {task_id}")

# --- advance current_pointer in both status and roadmap ---
def advance_pointer(data: dict) -> str | None:
    """Return the next non-completed task id, or None if all completed."""
    for task in data["tasks"]:
        if task.get("status") != "completed":
            return task["id"]
    return None

next_pointer = advance_pointer(status_data)
if next_pointer is None:
    print(f"[warn] all tasks in {track} track are completed; current_pointer unchanged")
else:
    status_data["current_pointer"] = next_pointer
    roadmap_data["current_pointer"] = next_pointer
    print(f"[ok] advanced current_pointer to {next_pointer}")

# --- atomic write via temp file + rename ---
now_iso = datetime.now(timezone.utc).isoformat()
status_data["updated_at"] = now_iso
roadmap_data["updated_at"] = now_iso

def atomic_write_json(target: Path, data: dict) -> None:
    """Write JSON to a temp file in the same directory, validate, then atomically rename."""
    tmp = target.with_suffix(".tmp." + next(tempfile._get_candidate_names()))
    try:
        content = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
        tmp.write_text(content, encoding="utf-8")
        # validate: re-read and parse
        json.loads(tmp.read_text(encoding="utf-8"))
        tmp.replace(target)
    finally:
        if tmp.exists():
            tmp.unlink()

atomic_write_json(status_path, status_data)
print(f"[ok] completed {task_id} in {status_path}")

atomic_write_json(roadmap_path, roadmap_data)
print(f"[ok] completed {task_id} in {roadmap_path}")
PY_TASK_CLOSE
python3 scripts/orchestrator/generate-next-task.py --track "$TRACK" --write

# --- regression guard: verify pointer equality across status, roadmap, and NEXT_TASK ---
STATUS_POINTER="$(python3 -c "import json; print(json.load(open('tasks/status/${TRACK}.json'))['current_pointer'])")"
ROADMAP_POINTER="$(python3 -c "import json; print(json.load(open('tasks/roadmap/${TRACK}.json'))['current_pointer'])")"
NEXT_TASK_ID="$(python3 -c "import re; print(re.search(r'Task ID: \x60([^\x60]+)\x60', open('tasks/active/${TRACK}/NEXT_TASK.md').read()).group(1))")"

FAILED_GUARD=0
if [ "$STATUS_POINTER" != "$ROADMAP_POINTER" ]; then
  echo "[error] regression guard: status.current_pointer (${STATUS_POINTER}) != roadmap.current_pointer (${ROADMAP_POINTER})" >&2
  FAILED_GUARD=1
fi
if [ "$NEXT_TASK_ID" != "$STATUS_POINTER" ]; then
  echo "[error] regression guard: NEXT_TASK.md Task ID (${NEXT_TASK_ID}) != status.current_pointer (${STATUS_POINTER})" >&2
  FAILED_GUARD=1
fi
if [ "$NEXT_TASK_ID" != "$ROADMAP_POINTER" ]; then
  echo "[error] regression guard: NEXT_TASK.md Task ID (${NEXT_TASK_ID}) != roadmap.current_pointer (${ROADMAP_POINTER})" >&2
  FAILED_GUARD=1
fi
if [ "$NEXT_TASK_ID" = "$TASK_ID" ]; then
  echo "[error] regression guard: NEXT_TASK.md still points at closed task ${TASK_ID}" >&2
  FAILED_GUARD=1
fi
if [ "$FAILED_GUARD" -ne 0 ]; then
  exit 1
fi
echo "[ok] regression guard: pointers consistent (status=${STATUS_POINTER}, roadmap=${ROADMAP_POINTER}, next_task=${NEXT_TASK_ID})"
