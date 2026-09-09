#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import json
import os
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(os.environ.get("PLATFORMINIT_REPO_ROOT", Path(__file__).resolve().parents[2])).resolve()
TRACKER = ROOT / "tasks" / "tracker.json"
ACTIVE = ROOT / "tasks" / "active"
VALID = {"pending", "in_progress", "needs_review", "needs_security_review", "ready_to_close", "blocked", "done"}
ACTIVE_STATES = {"in_progress", "needs_review", "needs_security_review", "ready_to_close"}
ORCHESTRATOR = "platforminit-orchestrator"
REVIEWER = "platforminit-openai-reviewer"
OWASP = "platforminit-owasp-reviewer"
RELEASE = "platforminit-release-manager"
LEGACY = [
    "tasks/status/platform.json", "tasks/status/n8n.json",
    "tasks/roadmap/platform.json", "tasks/roadmap/n8n.json",
    "tasks/active/CURRENT_ACTIVE_TASKS.md", "tasks/active/NEXT_TASK_AGENT_LAYER.md",
    "docs/roo-lab/context/ACTIVE_AGENT_CONTEXT.md",
]
SCOPE_EXCLUSIONS = (
    "tasks/tracker.json",
    "tasks/active/",
    "docs/reviews/",
    "docs/security-reviews/",
)


class TaskError(RuntimeError):
    pass


def now():
    return datetime.now(timezone.utc).isoformat()


def load():
    if not TRACKER.exists():
        raise TaskError("tasks/tracker.json does not exist")
    return json.loads(TRACKER.read_text(encoding="utf-8"))


def write_json(data):
    data["updatedAt"] = now()
    tmp = TRACKER.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(TRACKER)


def by_id(data):
    return {task["id"]: task for task in data["tasks"]}


def deps_done(task, data):
    mapping = by_id(data)
    return all(mapping[dependency]["status"] == "done" for dependency in task["dependsOn"])


def active_task(data, track):
    found = [task for task in data["tasks"] if task["track"] == track and task["status"] in ACTIVE_STATES]
    return sorted(found, key=lambda task: (task["order"], task["id"]))[0] if found else None


def next_task(data, track):
    current = active_task(data, track)
    if current:
        return current
    found = [
        task for task in data["tasks"]
        if task["track"] == track and task["status"] == "pending" and deps_done(task, data)
    ]
    return sorted(found, key=lambda task: (task["order"], task["id"]))[0] if found else None


def get_task(data, task_id):
    task = by_id(data).get(task_id)
    if not task:
        raise TaskError(f"unknown task {task_id}")
    return task


def current_branch():
    result = subprocess.run(["git", "branch", "--show-current"], cwd=ROOT, text=True, capture_output=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def require_branch(task):
    branch = current_branch()
    if branch != task["branch"]:
        raise TaskError(f"{task['id']}: branch-task mismatch; expected {task['branch']}, current {branch or '<detached>'}")


def workflow_state_errors(task):
    status = task["status"]
    workflow = task.get("workflow", {})
    errors = []
    if status in ACTIVE_STATES and not workflow.get("startedAt"):
        errors.append(f"{task['id']}: {status} requires workflow.startedAt")
    if status in {"needs_review", "needs_security_review", "ready_to_close"} and not workflow.get("submit"):
        errors.append(f"{task['id']}: {status} requires workflow.submit")
    if status in {"needs_security_review", "ready_to_close"} and workflow.get("review", {}).get("verdict") != "approve":
        errors.append(f"{task['id']}: {status} requires approving workflow.review")
    if status == "ready_to_close" and workflow.get("security", {}).get("verdict") != "clear":
        errors.append(f"{task['id']}: ready_to_close requires clear workflow.security")
    if status == "blocked":
        blocker = task.get("blocker", {})
        if blocker.get("previousStatus") not in VALID - {"blocked", "done"}:
            errors.append(f"{task['id']}: blocked state requires a legal blocker.previousStatus")
    return errors


def validate_tracker(data):
    errors = []
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    tracks = [track.get("id") for track in data.get("tracks", [])]
    ids, mapping = set(), {}
    for task in data.get("tasks", []):
        task_id = task.get("id")
        if not task_id:
            errors.append("task id missing")
            continue
        if task_id in ids:
            errors.append(f"duplicate task id {task_id}")
        ids.add(task_id)
        mapping[task_id] = task
        if task.get("track") not in tracks:
            errors.append(f"{task_id}: unknown track {task.get('track')}")
        if task.get("status") not in VALID:
            errors.append(f"{task_id}: invalid status {task.get('status')}")
        if not isinstance(task.get("order"), int):
            errors.append(f"{task_id}: order must be an integer")
        for field in ("branch", "description", "scope", "implementationMode", "reviewMode", "securityMode", "releaseMode"):
            if not task.get(field):
                errors.append(f"{task_id}: {field} missing")
        for field in ("dependsOn", "acceptanceCriteria", "allowedFiles", "requiredValidators"):
            if not isinstance(task.get(field), list) or not task[field]:
                if field == "dependsOn" and task.get(field) == []:
                    continue
                errors.append(f"{task_id}: {field} missing")
        errors.extend(workflow_state_errors(task))

    for task in data.get("tasks", []):
        for dependency in task.get("dependsOn", []):
            if dependency not in ids:
                errors.append(f"{task['id']}: missing dependency {dependency}")
            if dependency == task["id"]:
                errors.append(f"{task['id']}: self-dependency")

    visiting, visited = set(), set()
    def visit(task_id):
        if task_id in visiting:
            errors.append(f"{task_id}: dependency cycle")
            return
        if task_id in visited or task_id not in mapping:
            return
        visiting.add(task_id)
        for dependency in mapping[task_id].get("dependsOn", []):
            visit(dependency)
        visiting.remove(task_id)
        visited.add(task_id)
    for task_id in ids:
        visit(task_id)

    for track in tracks:
        active = [task["id"] for task in data.get("tasks", []) if task.get("track") == track and task.get("status") in ACTIVE_STATES]
        if len(active) > 1:
            errors.append(f"{track}: only one active task allowed; found {', '.join(active)}")
    return errors


def transition(task):
    task_id = task["id"]
    if task["status"] == "pending":
        return ORCHESTRATOR, f"python3 tools/task_controller/taskctl.py start {task_id} --actor {ORCHESTRATOR}"
    if task["status"] == "in_progress":
        actor = task["implementationMode"]
        return actor, f"python3 tools/task_controller/taskctl.py submit {task_id} --actor {actor}"
    if task["status"] == "needs_review":
        return REVIEWER, f"python3 tools/task_controller/taskctl.py review {task_id} --actor {REVIEWER} --verdict approve --report docs/reviews/{task_id}.md"
    if task["status"] == "needs_security_review":
        return OWASP, f"python3 tools/task_controller/taskctl.py security {task_id} --actor {OWASP} --verdict clear --report docs/security-reviews/{task_id}.md"
    if task["status"] == "ready_to_close":
        return RELEASE, f"python3 tools/task_controller/taskctl.py complete {task_id} --actor {RELEASE}"
    return "none", "none"


def render_task(task, track):
    if not task:
        return f"# {track} task view\n\nGenerated from `tasks/tracker.json`. Do not edit manually.\n\nNo runnable task exists.\n"
    actor, command = transition(task)
    acceptance = "\n".join(f"- [ ] {item}" for item in task["acceptanceCriteria"])
    allowed = "\n".join(f"- `{item}`" for item in task["allowedFiles"])
    validators = "\n".join(f"- `{' '.join(command)}`" for command in task["requiredValidators"])
    forbidden = "\n".join(f"- {item}" for item in task.get("forbiddenActions", [])) or "- none"
    dependencies = ", ".join(task["dependsOn"]) or "none"
    return f"""# {track} task view

Generated from `tasks/tracker.json`. Do not edit manually.

## {task['id']} — {task['title']}

| Field | Value |
|---|---|
| Status | `{task['status']}` |
| Track | `{track}` |
| Branch | `{task['branch']}` |
| Scope | `{task['scope']}` |
| Dependencies | {dependencies} |
| Next actor | `{actor}` |

{task['description']}

### Acceptance criteria

{acceptance}

### Allowed files

{allowed}

### Required validators

{validators}

### Forbidden actions

{forbidden}

### Controller transition

`{command}`
"""


def render_dashboard(data):
    lines = [
        "# PlatformInit task dashboard", "",
        "Generated from `tasks/tracker.json`. Do not edit manually.", "",
        "`tasks/tracker.json` is the only authoritative task registry and mutable task state.", "",
        "| Track | Current / next | Status | Branch |", "|---|---|---|---|",
    ]
    for track in [item["id"] for item in data["tracks"]]:
        task = next_task(data, track)
        lines.append(f"| `{track}` | `{task['id']}` — {task['title']} | `{task['status']}` | `{task['branch']}` |" if task else f"| `{track}` | none | complete/blocked | — |")
    lines += ["", "Use `python3 tools/task_controller/taskctl.py next --check` for drift detection.", ""]
    return "\n".join(lines)


def expected_views(data):
    views = {ACTIVE / "NEXT_TASK.md": render_dashboard(data)}
    for track in [item["id"] for item in data["tracks"]]:
        views[ACTIVE / track / "NEXT_TASK.md"] = render_task(next_task(data, track), track)
    return views


def sync_views(data, check=False):
    errors = []
    for path, content in expected_views(data).items():
        if check:
            if not path.exists():
                errors.append(f"generated view missing: {path.relative_to(ROOT)}")
            elif path.read_text(encoding="utf-8") != content:
                errors.append(f"generated view stale: {path.relative_to(ROOT)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
    return errors


def integrity(data, ignore_branch=False):
    errors = validate_tracker(data) + sync_views(data, check=True)
    for relative in LEGACY:
        if (ROOT / relative).exists():
            errors.append(f"obsolete authoritative artifact still exists: {relative}")
    if not ignore_branch:
        branch = current_branch()
        for task in data["tasks"]:
            if task["status"] in ACTIVE_STATES and branch != task["branch"]:
                errors.append(f"{task['id']}: branch-task mismatch; expected {task['branch']}, current {branch or '<detached>'}")
    return errors


def changed_files(base="dev"):
    files = set()
    commands = [
        ["git", "diff", "--name-only", f"{base}...HEAD"],
        ["git", "diff", "--name-only"],
        ["git", "diff", "--cached", "--name-only"],
        ["git", "ls-files", "--others", "--exclude-standard"],
    ]
    for command in commands:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
        if result.returncode == 0:
            files.update(line.strip() for line in result.stdout.splitlines() if line.strip())
    return sorted(file for file in files if not any(file == prefix or file.startswith(prefix) for prefix in SCOPE_EXCLUSIONS))


def require_allowed_scope(task):
    disallowed = [file for file in changed_files() if not any(fnmatch.fnmatch(file, pattern) for pattern in task["allowedFiles"])]
    if disallowed:
        raise TaskError(f"{task['id']}: changed files outside allowedFiles: {', '.join(disallowed)}")


def run_validators(task):
    records = []
    for command in task["requiredValidators"]:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
        records.append({"command": command, "exitCode": result.returncode})
        if result.returncode:
            excerpt = (result.stdout + "\n" + result.stderr).strip()[-2000:]
            raise TaskError(f"{task['id']}: validator failed ({' '.join(command)}): {excerpt or 'no output'}")
    return records


def report(path, label):
    absolute = (ROOT / path).resolve()
    if not str(absolute).startswith(str(ROOT) + os.sep):
        raise TaskError(f"{label} report must stay inside repository")
    if not absolute.exists():
        raise TaskError(f"{label} report does not exist: {path}")
    if len(absolute.read_text(encoding="utf-8").strip()) < 40:
        raise TaskError(f"{label} report too short: {path}")
    return str(absolute.relative_to(ROOT))


def save(data):
    write_json(data)
    sync_views(data)


def make_parser():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)
    next_parser = sub.add_parser("next")
    next_parser.add_argument("--track", choices=["platform", "n8n"])
    next_parser.add_argument("--check", action="store_true")
    list_parser = sub.add_parser("list")
    list_parser.add_argument("--track", choices=["platform", "n8n"])
    branch_parser = sub.add_parser("branch")
    branch_parser.add_argument("--track", required=True, choices=["platform", "n8n"])
    validate_parser = sub.add_parser("validate")
    validate_parser.add_argument("--sync", action="store_true")
    validate_parser.add_argument("--ignore-branch", action="store_true")
    for command in ("start", "submit", "complete", "unblock"):
        action = sub.add_parser(command)
        action.add_argument("task_id")
        action.add_argument("--actor", required=True)
    review = sub.add_parser("review")
    review.add_argument("task_id"); review.add_argument("--actor", required=True); review.add_argument("--verdict", required=True, choices=["approve", "request_changes", "block"]); review.add_argument("--report", required=True)
    security = sub.add_parser("security")
    security.add_argument("task_id"); security.add_argument("--actor", required=True); security.add_argument("--verdict", required=True, choices=["clear", "review_required", "block"]); security.add_argument("--report", required=True)
    block = sub.add_parser("block")
    block.add_argument("task_id"); block.add_argument("--actor", required=True); block.add_argument("--reason", required=True)
    return parser


def main():
    args = make_parser().parse_args()
    try:
        data = load()
        errors = validate_tracker(data)
        if errors:
            raise TaskError("tracker validation failed:\n- " + "\n- ".join(errors))

        if args.cmd == "next":
            if args.check:
                errors = sync_views(data, check=True)
                if errors:
                    raise TaskError("\n- ".join(errors))
                print("Generated task views are current.")
            else:
                sync_views(data)
                print(render_task(next_task(data, args.track), args.track) if args.track else render_dashboard(data))
            return 0
        if args.cmd == "list":
            for task in data["tasks"]:
                if not args.track or task["track"] == args.track:
                    print(f"{task['id']}\t{task['track']}\t{task['status']}\t{task['title']}")
            return 0
        if args.cmd == "branch":
            task = next_task(data, args.track)
            if not task:
                raise TaskError(f"no runnable task for {args.track}")
            print(task["branch"])
            return 0
        if args.cmd == "validate":
            if args.sync:
                sync_views(data)
            errors = integrity(data, ignore_branch=args.ignore_branch)
            if errors:
                raise TaskError("integrity validation failed:\n- " + "\n- ".join(errors))
            print("Task tracker and generated views are valid.")
            return 0

        task = get_task(data, args.task_id)
        if args.cmd == "start":
            if task["status"] != "pending":
                raise TaskError(f"{task['id']} is {task['status']}, not pending")
            if active_task(data, task["track"]):
                raise TaskError(f"{task['track']} already has an active task")
            if not deps_done(task, data):
                raise TaskError(f"{task['id']} has incomplete dependencies")
            if args.actor != ORCHESTRATOR:
                raise TaskError(f"{task['id']} must be started by {ORCHESTRATOR}")
            require_branch(task)
            task["status"] = "in_progress"
            task["workflow"] = {"startedAt": now(), "startedBy": args.actor, "implementationActor": task["implementationMode"]}
            save(data)
        elif args.cmd == "submit":
            if task["status"] != "in_progress":
                raise TaskError(f"{task['id']} is {task['status']}, not in_progress")
            if args.actor != task["implementationMode"]:
                raise TaskError(f"{task['id']} must be submitted by {task['implementationMode']}")
            require_branch(task)
            require_allowed_scope(task)
            task.setdefault("workflow", {})["submit"] = {"at": now(), "actor": args.actor, "validators": run_validators(task)}
            task["status"] = "needs_review"
            save(data)
        elif args.cmd == "review":
            if task["status"] != "needs_review":
                raise TaskError(f"{task['id']} is {task['status']}, not needs_review")
            if args.actor != REVIEWER or args.actor != task["reviewMode"]:
                raise TaskError(f"review must use {REVIEWER}")
            if args.actor == task.get("workflow", {}).get("implementationActor"):
                raise TaskError("implementation actor cannot review its own task")
            report_path = report(args.report, "review")
            task.setdefault("workflow", {})["review"] = {"at": now(), "actor": args.actor, "verdict": args.verdict, "report": report_path}
            if args.verdict == "approve":
                task["status"] = "needs_security_review"
            elif args.verdict == "request_changes":
                task["status"] = "in_progress"
            else:
                task["blocker"] = {"at": now(), "actor": args.actor, "reason": "review verdict block", "stage": "review", "report": report_path, "previousStatus": "needs_review"}
                task["status"] = "blocked"
            save(data)
        elif args.cmd == "security":
            if task["status"] != "needs_security_review":
                raise TaskError(f"{task['id']} is {task['status']}, not needs_security_review")
            if args.actor != OWASP or args.actor != task["securityMode"]:
                raise TaskError(f"security review must use {OWASP}")
            if args.actor == task.get("workflow", {}).get("implementationActor"):
                raise TaskError("implementation actor cannot security-review its own task")
            report_path = report(args.report, "security")
            task.setdefault("workflow", {})["security"] = {"at": now(), "actor": args.actor, "verdict": args.verdict, "report": report_path}
            if args.verdict == "clear":
                task["status"] = "ready_to_close"
            elif args.verdict == "review_required":
                task["status"] = "in_progress"
            else:
                task["blocker"] = {"at": now(), "actor": args.actor, "reason": "security verdict block", "stage": "security", "report": report_path, "previousStatus": "needs_security_review"}
                task["status"] = "blocked"
            save(data)
        elif args.cmd == "complete":
            if task["status"] != "ready_to_close":
                raise TaskError(f"{task['id']} is {task['status']}, not ready_to_close")
            if args.actor != RELEASE or args.actor != task["releaseMode"]:
                raise TaskError(f"only {RELEASE} may close a task")
            workflow = task.get("workflow", {})
            if workflow.get("review", {}).get("verdict") != "approve" or workflow.get("security", {}).get("verdict") != "clear":
                raise TaskError(f"{task['id']} lacks passing review/security records")
            require_branch(task)
            require_allowed_scope(task)
            workflow["complete"] = {"at": now(), "actor": args.actor, "validators": run_validators(task)}
            task["status"] = "done"
            task.pop("blocker", None)
            save(data)
        elif args.cmd == "block":
            if task["status"] == "done":
                raise TaskError("completed task cannot be blocked")
            previous = task["status"]
            task["status"] = "blocked"
            task["blocker"] = {"at": now(), "actor": args.actor, "reason": args.reason, "previousStatus": previous}
            save(data)
        elif args.cmd == "unblock":
            if task["status"] != "blocked":
                raise TaskError(f"{task['id']} is {task['status']}, not blocked")
            if args.actor != ORCHESTRATOR:
                raise TaskError(f"only {ORCHESTRATOR} may unblock")
            previous = task.get("blocker", {}).get("previousStatus")
            if previous not in VALID - {"blocked", "done"}:
                raise TaskError(f"{task['id']} blocker has no legal previousStatus")
            task["status"] = previous
            task.pop("blocker", None)
            save(data)
        return 0
    except (TaskError, json.JSONDecodeError) as exc:
        print(f"taskctl: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
