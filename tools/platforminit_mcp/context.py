"""Compact, platform-only delivery context for PlatformInit Zoo children.

This module serves exactly one delivery track (`platform`). Separate delivery tracks, such as the
standalone n8n track, are never selected, summarised, or routed here: there is no project/track
branching in this module, only the single PlatformInit queue plus an explicit exclusion of
foreign-track paths from the changed-scope window.

The delivery payload is intentionally reduced to stage-critical fields: the active task, the bounded
changed scope, and the next controller transition. Prose handoff rules live in
`docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md`, not in every MCP response.
"""
from __future__ import annotations

import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TRACKER = ROOT / "tasks" / "tracker.json"

PROJECT = "platforminit"
CONTEXT_VERSION = 3
PLATFORM_TRACK = "platform"

ACTIVE_STATES = {"in_progress", "needs_review", "needs_security_review", "ready_to_close"}

STAGE_BY_STATUS = {
    "pending": "start",
    "in_progress": "implementation",
    "needs_review": "review",
    "needs_security_review": "security-review",
    "ready_to_close": "release",
    "blocked": "blocked",
    "done": "closed",
}

# Controller-owned or generated state is never a delivery artifact.
STATE_EXCLUSIONS = (
    "tasks/tracker.json",
    "tasks/active/",
    "docs/reviews/",
    "docs/security-reviews/",
)

# Paths owned by a separate delivery track must not leak into PlatformInit delivery context.
FOREIGN_TRACK_PATHS = (
    "n8n/",
    "docs/n8n/",
)

# Small-task budget: a fresh child needs the active task, not the whole repository diff.
SCOPE_DEFAULT_FILES = 5
SCOPE_HARD_CAP_FILES = 8
FOCUSED_TEST_LIMIT = 3

HANDOFF_PAYLOAD = (
    "task id",
    "stage",
    "acceptance gaps",
    "changed paths",
    "evidence paths",
    "unresolved risks",
    "controller transition",
)

AUTHORITATIVE_TASK_SOURCE = "tasks/tracker.json"


def clamp_max_files(max_files: object) -> int:
    """Bound any requested changed-file window to the small-task hard cap."""
    try:
        requested = int(max_files)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        requested = SCOPE_DEFAULT_FILES
    return max(1, min(requested, SCOPE_HARD_CAP_FILES))


def _matches(path: str, prefixes: tuple[str, ...]) -> bool:
    return any(path == prefix.rstrip("/") or path.startswith(prefix) for prefix in prefixes)


def _tracker() -> dict:
    return json.loads(TRACKER.read_text(encoding="utf-8"))


def _platform_tasks() -> list[dict]:
    return [task for task in _tracker()["tasks"] if task.get("track") == PLATFORM_TRACK]


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


def changed_scope(base: str = "dev", max_files: int = SCOPE_DEFAULT_FILES) -> dict:
    limit = clamp_max_files(max_files)
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
    visible: list[str] = []
    foreign_excluded = 0
    for file in sorted(files):
        if _matches(file, FOREIGN_TRACK_PATHS):
            foreign_excluded += 1
            continue
        if _matches(file, STATE_EXCLUSIONS):
            continue
        visible.append(file)
    tests = [file for file in visible if "test" in Path(file).name.lower()]
    return {
        "base": base,
        "platformOnly": True,
        "fileCount": len(visible),
        "files": visible[:limit],
        "truncated": len(visible) > limit,
        "focusedTests": tests[:FOCUSED_TEST_LIMIT],
        "foreignPathsExcluded": foreign_excluded,
        "budget": {"target": 3, "warning": 5, "hardSplitAbove": 5, "hardCap": SCOPE_HARD_CAP_FILES},
    }


def stage(task: dict) -> str:
    return STAGE_BY_STATUS.get(task["status"], "unknown")


def transition(task: dict) -> dict:
    status = task["status"]
    tid = task["id"]
    if status == "pending":
        return {
            "stage": stage(task),
            "nextMode": "platforminit-orchestrator",
            "command": f"python3 tools/task_controller/taskctl.py start {tid} --actor platforminit-orchestrator",
        }
    if status == "in_progress":
        actor = task["implementationMode"]
        return {
            "stage": stage(task),
            "nextMode": actor,
            "command": f"python3 tools/task_controller/taskctl.py submit {tid} --actor {actor}",
        }
    if status == "needs_review":
        return {
            "stage": stage(task),
            "nextMode": task["reviewMode"],
            "command": f"python3 tools/task_controller/taskctl.py review {tid} --actor {task['reviewMode']} --verdict <approve|request_changes|block> --report docs/reviews/{tid}.md",
        }
    if status == "needs_security_review":
        return {
            "stage": stage(task),
            "nextMode": task["securityMode"],
            "command": f"python3 tools/task_controller/taskctl.py security {tid} --actor {task['securityMode']} --verdict <clear|review_required|block> --report docs/security-reviews/{tid}.md",
        }
    if status == "ready_to_close":
        return {
            "stage": stage(task),
            "nextMode": task["releaseMode"],
            "command": f"python3 tools/task_controller/taskctl.py complete {tid} --actor {task['releaseMode']}",
        }
    return {"stage": stage(task), "nextMode": None, "command": None}


def active_task_summary(task_id: str | None = None) -> dict:
    task = select_task(task_id=task_id)
    if not task:
        state = "unknown-platform-task" if task_id else "no-runnable-platform-task"
        return {"state": state, "track": PLATFORM_TRACK}
    return {
        "id": task["id"],
        "track": PLATFORM_TRACK,
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


def delivery_context(task_id: str | None = None, base: str = "dev", max_files: int = SCOPE_DEFAULT_FILES) -> dict:
    return {
        "contextVersion": CONTEXT_VERSION,
        "project": PROJECT,
        "track": PLATFORM_TRACK,
        "task": active_task_summary(task_id=task_id),
        "scope": changed_scope(base=base, max_files=max_files),
        "handoff": {"payload": list(HANDOFF_PAYLOAD)},
        "authoritativeTaskSource": AUTHORITATIVE_TASK_SOURCE,
    }
