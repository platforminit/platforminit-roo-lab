#!/usr/bin/env python3
from __future__ import annotations

import argparse
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
    return {t["id"]: t for t in data["tasks"]}

def deps_done(task, data):
    mapping = by_id(data)
    return all(mapping[d]["status"] == "done" for d in task["dependsOn"])

def active_task(data, track):
    found = [t for t in data["tasks"] if t["track"] == track and t["status"] in ACTIVE_STATES]
    return sorted(found, key=lambda t: (t["order"], t["id"]))[0] if found else None

def next_task(data, track):
    current = active_task(data, track)
    if current:
        return current
    found = [t for t in data["tasks"] if t["track"] == track and t["status"] == "pending" and deps_done(t, data)]
    return sorted(found, key=lambda t: (t["order"], t["id"]))[0] if found else None

def get_task(data, task_id):
    task = by_id(data).get(task_id)
    if not task:
        raise TaskError(f"unknown task {task_id}")
    return task

def current_branch():
    p = subprocess.run(["git", "branch", "--show-current"], cwd=ROOT, text=True, capture_output=True)
    return p.stdout.strip() if p.returncode == 0 else ""

def require_branch(task):
    branch = current_branch()
    if branch != task["branch"]:
        raise TaskError(f"{task['id']}: branch-task mismatch; expected {task['branch']}, current {branch or '<detached>'}")

def validate_tracker(data):
    errors = []
    if data.get("schemaVersion") != 1:
        errors.append("schemaVersion must be 1")
    tracks = [t.get("id") for t in data.get("tracks", [])]
    ids, mapping = set(), {}
    for task in data.get("tasks", []):
        tid = task.get("id")
        if not tid:
            errors.append("task id missing")
            continue
        if tid in ids:
            errors.append(f"duplicate task id {tid}")
        ids.add(tid); mapping[tid] = task
        if task.get("track") not in tracks:
            errors.append(f"{tid}: unknown track {task.get('track')}")
        if task.get("status") not in VALID:
            errors.append(f"{tid}: invalid status {task.get('status')}")
        for field in ("branch", "description", "scope", "implementationMode", "reviewMode", "securityMode", "releaseMode"):
            if not task.get(field): errors.append(f"{tid}: {field} missing")
        for field in ("dependsOn", "acceptanceCriteria", "allowedFiles", "requiredValidators"):
            if not isinstance(task.get(field), list) or not task[field]:
                if field == "dependsOn" and task.get(field) == []: continue
                errors.append(f"{tid}: {field} missing")
    for task in data.get("tasks", []):
        for dep in task.get("dependsOn", []):
            if dep not in ids: errors.append(f"{task['id']}: missing dependency {dep}")
            if dep == task["id"]: errors.append(f"{task['id']}: self-dependency")
    visiting, visited = set(), set()
    def visit(tid):
        if tid in visiting:
            errors.append(f"{tid}: dependency cycle"); return
        if tid in visited or tid not in mapping: return
        visiting.add(tid)
        for dep in mapping[tid].get("dependsOn", []): visit(dep)
        visiting.remove(tid); visited.add(tid)
    for tid in ids: visit(tid)
    for track in tracks:
        actives = [t["id"] for t in data.get("tasks", []) if t.get("track") == track and t.get("status") in ACTIVE_STATES]
        if len(actives) > 1: errors.append(f"{track}: only one active task allowed; found {', '.join(actives)}")
    return errors

def transition(task):
    tid = task["id"]
    if task["status"] == "pending": return ORCHESTRATOR, f"python3 tools/task_controller/taskctl.py start {tid} --actor {ORCHESTRATOR}"
    if task["status"] == "in_progress": return task["implementationMode"], f"python3 tools/task_controller/taskctl.py submit {tid} --actor {task['implementationMode']}"
    if task["status"] == "needs_review": return REVIEWER, f"python3 tools/task_controller/taskctl.py review {tid} --actor {REVIEWER} --verdict approve --report docs/reviews/{tid}.md"
    if task["status"] == "needs_security_review": return OWASP, f"python3 tools/task_controller/taskctl.py security {tid} --actor {OWASP} --verdict clear --report docs/security-reviews/{tid}.md"
    if task["status"] == "ready_to_close": return RELEASE, f"python3 tools/task_controller/taskctl.py complete {tid} --actor {RELEASE}"
    return "none", "none"

def render_task(task, track):
    if not task:
        return f"# {track} task view\n\nGenerated from `tasks/tracker.json`. Do not edit manually.\n\nNo runnable task exists.\n"
    actor, command = transition(task)
    ac = "\n".join(f"- [ ] {x}" for x in task["acceptanceCriteria"])
    allowed = "\n".join(f"- `{x}`" for x in task["allowedFiles"])
    validators = "\n".join(f"- `{' '.join(x)}`" for x in task["requiredValidators"])
    forbidden = "\n".join(f"- {x}" for x in task.get("forbiddenActions", [])) or "- none"
    deps = ", ".join(task["dependsOn"]) or "none"
    return f"""# {track} task view

Generated from `tasks/tracker.json`. Do not edit manually.

## {task['id']} — {task['title']}

| Field | Value |
|---|---|
| Status | `{task['status']}` |
| Track | `{track}` |
| Branch | `{task['branch']}` |
| Scope | `{task['scope']}` |
| Dependencies | {deps} |
| Next actor | `{actor}` |

{task['description']}

### Acceptance criteria

{ac}

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
    lines = ["# PlatformInit task dashboard", "", "Generated from `tasks/tracker.json`. Do not edit manually.", "", "`tasks/tracker.json` is the only authoritative task registry and mutable task state.", "", "| Track | Current / next | Status | Branch |", "|---|---|---|---|"]
    for track in [t["id"] for t in data["tracks"]]:
        task = next_task(data, track)
        lines.append(f"| `{track}` | `{task['id']}` — {task['title']} | `{task['status']}` | `{task['branch']}` |" if task else f"| `{track}` | none | complete/blocked | — |")
    lines += ["", "Use `python3 tools/task_controller/taskctl.py next --check` for drift detection.", ""]
    return "\n".join(lines)

def expected_views(data):
    views = {ACTIVE / "NEXT_TASK.md": render_dashboard(data)}
    for track in [t["id"] for t in data["tracks"]]:
        views[ACTIVE / track / "NEXT_TASK.md"] = render_task(next_task(data, track), track)
    return views

def sync_views(data, check=False):
    errors = []
    for path, content in expected_views(data).items():
        if check:
            if not path.exists(): errors.append(f"generated view missing: {path.relative_to(ROOT)}")
            elif path.read_text(encoding="utf-8") != content: errors.append(f"generated view stale: {path.relative_to(ROOT)}")
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")
    return errors

def integrity(data, ignore_branch=False):
    errors = validate_tracker(data) + sync_views(data, check=True)
    for rel in LEGACY:
        if (ROOT / rel).exists(): errors.append(f"obsolete authoritative artifact still exists: {rel}")
    if not ignore_branch:
        branch = current_branch()
        for task in data["tasks"]:
            if task["status"] in ACTIVE_STATES and branch != task["branch"]:
                errors.append(f"{task['id']}: branch-task mismatch; expected {task['branch']}, current {branch or '<detached>'}")
    return errors

def run_validators(task):
    records = []
    for argv in task["requiredValidators"]:
        p = subprocess.run(argv, cwd=ROOT, text=True, capture_output=True)
        records.append({"command": argv, "exitCode": p.returncode})
        if p.returncode:
            excerpt = (p.stdout + "\n" + p.stderr).strip()[-2000:]
            raise TaskError(f"{task['id']}: validator failed ({' '.join(argv)}): {excerpt or 'no output'}")
    return records

def report(path, label):
    absolute = (ROOT / path).resolve()
    if not str(absolute).startswith(str(ROOT) + os.sep): raise TaskError(f"{label} report must stay inside repository")
    if not absolute.exists(): raise TaskError(f"{label} report does not exist: {path}")
    if len(absolute.read_text(encoding="utf-8").strip()) < 40: raise TaskError(f"{label} report too short: {path}")
    return str(absolute.relative_to(ROOT))

def save(data):
    write_json(data); sync_views(data)

def main():
    p = argparse.ArgumentParser()
    sp = p.add_subparsers(dest="cmd", required=True)
    n = sp.add_parser("next"); n.add_argument("--track", choices=["platform", "n8n"]); n.add_argument("--check", action="store_true")
    l = sp.add_parser("list"); l.add_argument("--track", choices=["platform", "n8n"])
    b = sp.add_parser("branch"); b.add_argument("--track", required=True, choices=["platform", "n8n"])
    v = sp.add_parser("validate"); v.add_argument("--sync", action="store_true"); v.add_argument("--ignore-branch", action="store_true")
    for cmd in ("start", "submit", "complete", "unblock"):
        q = sp.add_parser(cmd); q.add_argument("task_id"); q.add_argument("--actor", required=True)
    q = sp.add_parser("review"); q.add_argument("task_id"); q.add_argument("--actor", required=True); q.add_argument("--verdict", required=True, choices=["approve", "request_changes", "block"]); q.add_argument("--report", required=True)
    q = sp.add_parser("security"); q.add_argument("task_id"); q.add_argument("--actor", required=True); q.add_argument("--verdict", required=True, choices=["clear", "review_required", "block"]); q.add_argument("--report", required=True)
    q = sp.add_parser("block"); q.add_argument("task_id"); q.add_argument("--actor", required=True); q.add_argument("--reason", required=True)
    args = p.parse_args()
    try:
        data = load()
        errs = validate_tracker(data)
        if errs: raise TaskError("tracker validation failed:\n- " + "\n- ".join(errs))
        if args.cmd == "next":
            if args.check:
                errs = sync_views(data, check=True)
                if errs: raise TaskError("\n- ".join(errs))
                print("Generated task views are current.")
            else:
                sync_views(data); print(render_task(next_task(data, args.track), args.track) if args.track else render_dashboard(data))
        elif args.cmd == "list":
            for task in data["tasks"]:
                if not args.track or task["track"] == args.track: print(f"{task['id']}\t{task['track']}\t{task['status']}\t{task['title']}")
        elif args.cmd == "branch":
            task = next_task(data, args.track)
            if not task: raise TaskError(f"no runnable task for {args.track}")
            print(task["branch"])
        elif args.cmd == "validate":
            if args.sync: sync_views(data)
            errs = integrity(data, ignore_branch=args.ignore_branch)
            if errs: raise TaskError("integrity validation failed:\n- " + "\n- ".join(errs))
            print("Task tracker and generated views are valid.")
        else:
            task = get_task(data, args.task_id)
            if args.cmd == "start":
                if task["status"] != "pending": raise TaskError(f"{task['id']} is {task['status']}, not pending")
                if active_task(data, task["track"]): raise TaskError(f"{task['track']} already has an active task")
                if not deps_done(task, data): raise TaskError(f"{task['id']} has incomplete dependencies")
                if args.actor != ORCHESTRATOR: raise TaskError(f"{task['id']} must be started by {ORCHESTRATOR}")
                require_branch(task); task["status"] = "in_progress"; task["workflow"] = {"startedAt": now(), "startedBy": args.actor, "implementationActor": task["implementationMode"]}; save(data)
            elif args.cmd == "submit":
                if task["status"] != "in_progress": raise TaskError(f"{task['id']} is {task['status']}, not in_progress")
                if args.actor != task["implementationMode"]: raise TaskError(f"{task['id']} must be submitted by {task['implementationMode']}")
                require_branch(task); task.setdefault("workflow", {})["submit"] = {"at": now(), "actor": args.actor, "validators": run_validators(task)}; task["status"] = "needs_review"; save(data)
            elif args.cmd == "review":
                if task["status"] != "needs_review": raise TaskError(f"{task['id']} is {task['status']}, not needs_review")
                if args.actor != REVIEWER or args.actor != task["reviewMode"]: raise TaskError(f"review must use {REVIEWER}")
                rp = report(args.report, "review"); task.setdefault("workflow", {})["review"] = {"at": now(), "actor": args.actor, "verdict": args.verdict, "report": rp}; task["status"] = {"approve":"needs_security_review", "request_changes":"in_progress", "block":"blocked"}[args.verdict]; save(data)
            elif args.cmd == "security":
                if task["status"] != "needs_security_review": raise TaskError(f"{task['id']} is {task['status']}, not needs_security_review")
                if args.actor != OWASP or args.actor != task["securityMode"]: raise TaskError(f"security review must use {OWASP}")
                rp = report(args.report, "security"); task.setdefault("workflow", {})["security"] = {"at": now(), "actor": args.actor, "verdict": args.verdict, "report": rp}; task["status"] = {"clear":"ready_to_close", "review_required":"in_progress", "block":"blocked"}[args.verdict]; save(data)
            elif args.cmd == "complete":
                if task["status"] != "ready_to_close": raise TaskError(f"{task['id']} is {task['status']}, not ready_to_close")
                if args.actor != RELEASE or args.actor != task["releaseMode"]: raise TaskError(f"only {RELEASE} may close a task")
                wf = task.get("workflow", {})
                if wf.get("review", {}).get("verdict") != "approve" or wf.get("security", {}).get("verdict") != "clear": raise TaskError(f"{task['id']} lacks passing review/security records")
                require_branch(task); wf["complete"] = {"at": now(), "actor": args.actor, "validators": run_validators(task)}; task["status"] = "done"; save(data)
            elif args.cmd == "block":
                if task["status"] == "done": raise TaskError("completed task cannot be blocked")
                previous = task["status"]; task["status"] = "blocked"; task["blocker"] = {"at": now(), "actor": args.actor, "reason": args.reason, "previousStatus": previous}; save(data)
            elif args.cmd == "unblock":
                if task["status"] != "blocked": raise TaskError(f"{task['id']} is {task['status']}, not blocked")
                if args.actor != ORCHESTRATOR: raise TaskError(f"only {ORCHESTRATOR} may unblock")
                previous = task.get("blocker", {}).get("previousStatus", "pending"); task["status"] = previous if previous in VALID - {"blocked", "done"} else "pending"; task.pop("blocker", None); save(data)
        return 0
    except (TaskError, json.JSONDecodeError) as exc:
        print(f"taskctl: {exc}", file=sys.stderr); return 1

if __name__ == "__main__":
    raise SystemExit(main())
