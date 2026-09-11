from __future__ import annotations

import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TRACKER = ROOT / "tasks" / "tracker.json"
ACTIVE_STATES = {"in_progress", "needs_review", "needs_security_review", "ready_to_close"}
STATE_EXCLUSIONS = (
    "tasks/tracker.json",
    "tasks/active/",
    "docs/reviews/",
    "docs/security-reviews/",
)


def _tracker() -> dict:
    return json.loads(TRACKER.read_text(encoding="utf-8"))


def _platform_tasks() -> list[dict]:
    return [task for task in _tracker()["tasks"] if task.get("track") == "platform"]


def _deps_done(task: dict, mapping: dict[str, dict]) -> bool:
    return all(mapping[d]["status"] == "done" for d in task["dependsOn"])


def select_task(task_id: str | None = None) -> dict | None:
    tasks = _platform_tasks()
    if task_id:
        return next((task for task in tasks if task["id"] == task_id), None)
    mapping = {task["id"]: task for task in tasks}
    active = [task for task in tasks if task["status"] in ACTIVE_STATES]
    if active:
        return sorted(active, key=lambda task: (task["order"], task["id"]))[0]
    runnable = [task for task in tasks if task["status"] == "pending" and _deps_done(task, mapping)]
    return sorted(runnable, key=lambda task: (task["order"], task["id"]))[0] if runnable else None


def changed_scope(base: str = "dev", max_files: int = 12) -> dict:
    max_files = max(1, min(max_files, 20))
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
        if not any(file == prefix or file.startswith(prefix) for prefix in STATE_EXCLUSIONS)
    )
    tests = [file for file in visible if "test" in Path(file).name.lower()]
    return {
        "base": base,
        "fileCount": len(visible),
        "files": visible[:max_files],
        "truncated": len(visible) > max_files,
        "focusedTests": tests[:8],
        "budget": {"target": 3, "warning": 5, "hardSplitAbove": 5},
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


def active_task_summary(task_id: str | None = None) -> dict:
    task = select_task(task_id=task_id)
    if not task:
        return {"state": "no-runnable-platform-task"}
    return {
        "id": task["id"],
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


def delivery_context(task_id: str | None = None, base: str = "dev", max_files: int = 12) -> dict:
    task = active_task_summary(task_id=task_id)
    scope = changed_scope(base=base, max_files=max_files)
    allowed = task.get("allowedFiles", [])
    return {
        "contextVersion": 2,
        "project": "platforminit",
        "task": task,
        "scope": scope,
        "handoff": {
            "rule": "fresh Zoo child for every specialist stage; reload this context after child completion",
            "payload": ["task id", "stage", "acceptance gaps", "changed paths", "evidence paths", "unresolved risks", "controller transition"],
        },
        "indexing": {
            "strategy": "path-scoped codebase_search before raw reads",
            "suggestedPaths": allowed[:3],
        },
        "authoritativeTaskSource": "tasks/tracker.json",
    }
