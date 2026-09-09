from __future__ import annotations

import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TRACKER = ROOT / "tasks" / "tracker.json"
ACTIVE_STATES = {"in_progress", "needs_review", "needs_security_review", "ready_to_close"}


def _tracker() -> dict:
    return json.loads(TRACKER.read_text(encoding="utf-8"))


def _deps_done(task: dict, mapping: dict[str, dict]) -> bool:
    return all(mapping[d]["status"] == "done" for d in task["dependsOn"])


def select_task(track: str | None = None, task_id: str | None = None) -> dict | None:
    tracker = _tracker()
    tasks = tracker["tasks"]
    if task_id:
        return next((task for task in tasks if task["id"] == task_id), None)
    mapping = {task["id"]: task for task in tasks}
    candidates = [task for task in tasks if not track or task["track"] == track]
    active = [task for task in candidates if task["status"] in ACTIVE_STATES]
    if active:
        return sorted(active, key=lambda task: (task["track"], task["order"], task["id"]))[0]
    runnable = [task for task in candidates if task["status"] == "pending" and _deps_done(task, mapping)]
    return sorted(runnable, key=lambda task: (task["track"], task["order"], task["id"]))[0] if runnable else None


def changed_scope(base: str = "dev", max_files: int = 40) -> dict:
    max_files = max(1, min(max_files, 80))
    commands = [
        ["git", "diff", "--name-only", f"{base}...HEAD"],
        ["git", "diff", "--name-only"],
        ["git", "diff", "--cached", "--name-only"],
        ["git", "ls-files", "--others", "--exclude-standard"],
    ]
    files: set[str] = set()
    for command in commands:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
        if result.returncode == 0:
            files.update(line.strip() for line in result.stdout.splitlines() if line.strip())
    visible = sorted(
        file for file in files
        if file != "tasks/tracker.json"
        and not file.startswith("tasks/active/")
        and not file.startswith("docs/reviews/")
        and not file.startswith("docs/security-reviews/")
    )
    tests = [file for file in visible if "test" in Path(file).name.lower()]
    return {
        "base": base,
        "fileCount": len(visible),
        "files": visible[:max_files],
        "truncated": len(visible) > max_files,
        "focusedTests": tests[:20],
    }


def transition(task: dict) -> dict:
    status = task["status"]
    tid = task["id"]
    if status == "pending":
        return {"nextMode": "platforminit-orchestrator", "command": f"python3 tools/task_controller/taskctl.py start {tid} --actor platforminit-orchestrator"}
    if status == "in_progress":
        actor = task["implementationMode"]
        return {"nextMode": actor, "command": f"python3 tools/task_controller/taskctl.py submit {tid} --actor {actor}"}
    if status == "needs_review":
        return {"nextMode": task["reviewMode"], "command": f"python3 tools/task_controller/taskctl.py review {tid} --actor {task['reviewMode']} --verdict <approve|request_changes|block> --report docs/reviews/{tid}.md"}
    if status == "needs_security_review":
        return {"nextMode": task["securityMode"], "command": f"python3 tools/task_controller/taskctl.py security {tid} --actor {task['securityMode']} --verdict <clear|review_required|block> --report docs/security-reviews/{tid}.md"}
    if status == "ready_to_close":
        return {"nextMode": task["releaseMode"], "command": f"python3 tools/task_controller/taskctl.py complete {tid} --actor {task['releaseMode']}"}
    return {"nextMode": None, "command": None}


def active_task_summary(track: str | None = None, task_id: str | None = None) -> dict:
    task = select_task(track=track, task_id=task_id)
    if not task:
        return {"state": "no-runnable-task", "track": track}
    return {
        "id": task["id"],
        "track": task["track"],
        "status": task["status"],
        "title": task["title"],
        "scope": task["scope"],
        "branch": task["branch"],
        "dependsOn": task["dependsOn"],
        "acceptanceCriteria": task["acceptanceCriteria"],
        "allowedFiles": task["allowedFiles"],
        "requiredValidators": task["requiredValidators"],
        "forbiddenActions": task.get("forbiddenActions", []),
        **transition(task),
    }


def delivery_context(track: str | None = None, task_id: str | None = None, base: str = "dev", max_files: int = 40) -> dict:
    task = active_task_summary(track=track, task_id=task_id)
    scope = changed_scope(base=base, max_files=max_files)
    title = task.get("title") if task.get("id") else "current PlatformInit task"
    allowed = task.get("allowedFiles", [])
    return {
        "contextVersion": 1,
        "task": task,
        "scope": scope,
        "indexing": {
            "strategy": "path-scoped codebase_search before raw reads",
            "suggestedSearch": title,
            "suggestedPaths": allowed[:5],
        },
        "rag": {
            "status": "scaffold-only",
            "authoritativeTaskSource": "tasks/tracker.json",
            "rule": "retrieval may enrich context but must never become mutable task state",
        },
    }
