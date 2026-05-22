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
def advance_pointer_ordered(status_data: dict, roadmap_data: dict, closed_task_id: str) -> str:
    """
    Return the next eligible task id after closed_task_id using roadmap_order.
    Rules:
    1. Only tasks listed in roadmap_order are eligible.
    2. Legacy PLATFORM-* tasks are never selected unless roadmap_order is absent.
    3. Missing status (None or absent) is treated as ineligible, not as todo.
    4. Raises SystemExit if no valid ordered next task can be determined.
    """
    roadmap_order = roadmap_data.get("roadmap_order")
    if not roadmap_order:
        # Fallback: insertion-order iteration with same eligibility rules
        status_map = {t["id"]: t.get("status") for t in status_data["tasks"]}
        for task in status_data["tasks"]:
            tid = task["id"]
            task_status = status_map.get(tid)
            if task_status is None:
                # Missing status is not eligible
                continue
            if tid.startswith("PLATFORM-"):
                # Legacy PLATFORM-* tasks are not eligible without roadmap_order
                continue
            if task_status != "completed":
                return tid
        raise SystemExit(f"[error] no eligible next task found in {track} track (all completed or ineligible)")

    # Build lookup: task id -> status
    status_map = {t["id"]: t.get("status") for t in status_data["tasks"]}

    # Find closed_task_id in roadmap_order
    try:
        closed_idx = roadmap_order.index(closed_task_id)
    except ValueError:
        raise SystemExit(f"[error] closed task {closed_task_id} not found in roadmap_order")

    # Scan forward from closed_idx + 1
    for tid in roadmap_order[closed_idx + 1:]:
        task_status = status_map.get(tid)
        if task_status is None:
            # Missing status is not eligible
            continue
        if task_status != "completed":
            return tid

    raise SystemExit(f"[error] no eligible next task after {closed_task_id} in roadmap_order for {track} track")

next_pointer = advance_pointer_ordered(status_data, roadmap_data, task_id)
# Regression guard: never advance to a legacy PLATFORM-* task unless roadmap_order explicitly includes it
if next_pointer.startswith("PLATFORM-") and "PLATFORM-" not in str(roadmap_data.get("roadmap_order", [])):
    raise SystemExit(f"[error] advance would select legacy PLATFORM-* task {next_pointer} which is not in roadmap_order")
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
# --- regression guard: closing a P-* task must not advance to PLATFORM-* ---
if echo "$TASK_ID" | grep -q '^P-'; then
  if echo "$NEXT_TASK_ID" | grep -q '^PLATFORM-'; then
    echo "[error] regression guard: closing P-* task ${TASK_ID} advanced to legacy PLATFORM-* task ${NEXT_TASK_ID}" >&2
    FAILED_GUARD=1
  fi
fi
# --- regression guard: missing-status tasks are not eligible next tasks ---
NEXT_TASK_STATUS="$(python3 -c "
import json
s = json.load(open('tasks/status/${TRACK}.json'))
for t in s['tasks']:
    if t['id'] == s['current_pointer']:
        print(t.get('status', 'MISSING'))
        break
")"
if [ "$NEXT_TASK_STATUS" = "MISSING" ] || [ -z "$NEXT_TASK_STATUS" ]; then
  echo "[error] regression guard: next task ${NEXT_TASK_ID} has missing status (ineligible)" >&2
  FAILED_GUARD=1
fi
if [ "$FAILED_GUARD" -ne 0 ]; then
  exit 1
fi
echo "[ok] regression guard: pointers consistent (status=${STATUS_POINTER}, roadmap=${ROADMAP_POINTER}, next_task=${NEXT_TASK_ID})"
