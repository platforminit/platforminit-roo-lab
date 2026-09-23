#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone

ROOT = Path(os.environ.get("PLATFORMINIT_REPO_ROOT", Path(__file__).resolve().parents[2])).resolve()
TRACKER = ROOT / "tasks" / "tracker.json"
ACTIVE = ROOT / "tasks" / "active"
PLATFORM_TRACK = "platform"
VALID = {"pending", "in_progress", "needs_review", "needs_security_review", "ready_to_close", "blocked", "done"}
ACTIVE_STATES = {"in_progress", "needs_review", "needs_security_review", "ready_to_close"}
ORCHESTRATOR = "platforminit-orchestrator"
REVIEWER = "platforminit-openai-reviewer"
OWASP = "platforminit-owasp-reviewer"
RELEASE = "platforminit-release-manager"
# Micro-task sizing contract. Thresholds match the `scope.budget` fields the MCP delivery
# context advertises: target 3, warning 5, hardSplitAbove 5.
TASK_SIZE_TARGET = 3
TASK_SIZE_WARNING_MAX = 5
TASK_SIZE_HARD_SPLIT_ABOVE = TASK_SIZE_WARNING_MAX
LEGACY = [
    "tasks/status/platform.json", "tasks/status/n8n.json",
    "tasks/roadmap/platform.json", "tasks/roadmap/n8n.json",
    "tasks/active/CURRENT_ACTIVE_TASKS.md", "tasks/active/NEXT_TASK_AGENT_LAYER.md",
    "tasks/active/n8n/NEXT_TASK.md",
    "docs/roo-lab/context/ACTIVE_AGENT_CONTEXT.md",
]
SCOPE_EXCLUSIONS = (
    "tasks/tracker.json",
    "tasks/active/",
    "docs/reviews/",
    "docs/security-reviews/",
)
EVIDENCE_VERSION = 1
BASE_CANDIDATES = ("dev", "origin/dev", "main", "origin/main")
SUBMIT_EVIDENCE_FIELDS = ("actor", "at", "changedFiles", "evidenceVersion", "sourceFingerprint", "validators")
EVIDENCE_TRUST_BOUNDARY = (
    "evidence authenticity depends on tasks/tracker.json being controller-owned and never hand-edited; "
    "submit evidence is unauthenticated, so an actor with unrestricted write access to controller state "
    "can forge a fully consistent record and skip validators; authenticated or append-only evidence is an "
    "explicit follow-up and is not implemented in P-WF-T04"
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


def active_task(data, track=PLATFORM_TRACK):
    found = [task for task in data["tasks"] if task["track"] == track and task["status"] in ACTIVE_STATES]
    return sorted(found, key=lambda task: (task["order"], task["id"]))[0] if found else None


def next_task(data, track=PLATFORM_TRACK):
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
    if task.get("track") != PLATFORM_TRACK:
        raise TaskError(f"{task_id}: PlatformInit taskctl only manages the platform track")
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
    if status == "done" and workflow.get("reconciliation"):
        reconciliation = workflow["reconciliation"]
        required = ("at", "actor", "kind", "pullRequest", "mergeCommit", "ciRun", "reason", "limitations")
        missing = [field for field in required if not reconciliation.get(field)]
        if missing:
            errors.append(f"{task['id']}: reconciliation missing fields: {', '.join(missing)}")
        if reconciliation.get("kind") != "merged_without_controller_lifecycle":
            errors.append(f"{task['id']}: unsupported reconciliation kind")
        return errors
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
    if tracks != [PLATFORM_TRACK]:
        errors.append("PlatformInit tracker must contain exactly one track: platform")
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
        if task.get("track") != PLATFORM_TRACK:
            errors.append(f"{task_id}: non-platform task belongs in its own tracker, not tasks/tracker.json")
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

    active = [task["id"] for task in data.get("tasks", []) if task.get("status") in ACTIVE_STATES]
    if len(active) > 1:
        errors.append(f"platform: only one active task allowed; found {', '.join(active)}")
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


def render_task(task, track=PLATFORM_TRACK):
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
    task = next_task(data)
    lines = [
        "# PlatformInit task dashboard", "",
        "Generated from `tasks/tracker.json`. Do not edit manually.", "",
        "`tasks/tracker.json` is the only authoritative task registry and mutable task state.", "",
        "| Track | Current / next | Status | Branch |", "|---|---|---|---|",
        f"| `platform` | `{task['id']}` — {task['title']} | `{task['status']}` | `{task['branch']}` |" if task else "| `platform` | none | complete/blocked | — |",
        "", "Use `python3 tools/task_controller/taskctl.py next --check` for drift detection.", "",
    ]
    return "\n".join(lines)


def expected_views(data):
    return {
        ACTIVE / "NEXT_TASK.md": render_dashboard(data),
        ACTIVE / PLATFORM_TRACK / "NEXT_TASK.md": render_task(next_task(data)),
    }


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


def resolve_base(base="dev"):
    """Resolve the comparison base commit used by fingerprint and scope checks.

    Returns `(ref, sha)`, or `(None, None)` when the repository has no commits at all, in
    which case the index plus worktree is the complete source. When commits exist but no
    comparison base resolves the check fails loudly: a worktree-only fingerprint would hide
    committed source and could reuse stale validator evidence.
    """
    seen = []
    for candidate in (base, *BASE_CANDIDATES):
        if not candidate or candidate in seen:
            continue
        seen.append(candidate)
        result = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", f"{candidate}^{{commit}}"],
            cwd=ROOT, text=True, capture_output=True,
        )
        sha = result.stdout.strip()
        if result.returncode == 0 and sha:
            return candidate, sha
    head = subprocess.run(
        ["git", "rev-parse", "--verify", "--quiet", "HEAD^{commit}"],
        cwd=ROOT, text=True, capture_output=True,
    )
    if head.returncode == 0 and head.stdout.strip():
        raise TaskError(
            "cannot resolve a comparison base for the source fingerprint (tried: "
            + ", ".join(seen) + "); refusing to fingerprint a partial source scope"
        )
    return None, None


def changed_files(base="dev"):
    """Non-state files owned by the task: committed delta from base plus index and worktree."""
    _, sha = resolve_base(base)
    files = set()
    commands = []
    if sha:
        commands.append(["git", "diff", "--name-only", f"{sha}...HEAD"])
    commands.extend([
        ["git", "diff", "--name-only"],
        ["git", "diff", "--cached", "--name-only"],
        ["git", "ls-files", "--others", "--exclude-standard"],
    ])
    for command in commands:
        result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
        if result.returncode == 0:
            files.update(line.strip() for line in result.stdout.splitlines() if line.strip())
    return sorted(file for file in files if not any(file == prefix or file.startswith(prefix) for prefix in SCOPE_EXCLUSIONS))


def fingerprint_files(files):
    """Deterministic digest over exactly the supplied changed-file list.

    Per-file content hashes, a `<deleted>` marker for missing files, and no volatile input (time,
    actor, HEAD identity), so identical source always yields the same digest and any relevant source
    change yields a different one. This function never gathers the scope itself: the caller passes the
    one list it counted, will persist, and wants the digest to describe.
    """
    digest = hashlib.sha256()
    digest.update(b"platforminit-source-fingerprint-v1\0")
    for relative in files:
        path = ROOT / relative
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        if path.is_file():
            digest.update(hashlib.sha256(path.read_bytes()).hexdigest().encode("ascii"))
        else:
            digest.update(b"<deleted>")
        digest.update(b"\0")
    return digest.hexdigest()


def change_snapshot(base="dev"):
    """One gathered changed-file scope plus the fingerprint of exactly that list.

    The single-snapshot contract for every scope-based decision: the returned list is the only scope a
    caller may count, fingerprint, or persist, so the size gate can never judge one file set while the
    fingerprint and the recorded evidence describe another (P-WF-T05-D1). Scope is the committed delta
    from the resolved comparison base plus index and worktree; controller-owned state, generated views,
    and review reports are excluded, so regenerated views and state writes never invalidate evidence.
    """
    files = changed_files(base)
    return files, fingerprint_files(files)


def source_fingerprint(base="dev"):
    """Fingerprint of the current scope, returned in the historical `(fingerprint, files)` order."""
    files, fingerprint = change_snapshot(base)
    return fingerprint, files


def validator_plan(task):
    return tuple(tuple(command) for command in task["requiredValidators"])


def recorded_validator_plan(record):
    """Normalized validator commands from a submit record, or None when evidence is unusable.

    A record is usable only when every entry carries exactly a `command` vector of non-empty
    strings plus an integer `exitCode` of 0. Booleans, non-integers, non-zero exits, extra entry
    fields, and malformed vectors all make the evidence unusable so the caller reruns validators.
    """
    validators = record.get("validators") if isinstance(record, dict) else None
    if not isinstance(validators, list) or not validators:
        return None
    plan = []
    for item in validators:
        if not isinstance(item, dict) or set(item) != {"command", "exitCode"}:
            return None
        command = item.get("command")
        if not isinstance(command, list) or not command or not all(isinstance(part, str) and part for part in command):
            return None
        exit_code = item.get("exitCode")
        if isinstance(exit_code, bool) or not isinstance(exit_code, int) or exit_code != 0:
            return None
        plan.append(tuple(command))
    return tuple(plan)


def reusable_submit_evidence(task, record, fingerprint, files):
    """Fail-safe reuse decision: `(validators, None)` to reuse, or `(None, reason)` to rerun.

    Reuse requires versioned, complete, passing, shape-consistent submit evidence for the identical
    source scope and the identical validator plan, re-verified against a freshly recomputed
    fingerprint immediately before the decision. Missing, legacy, corrupt, partial, unknown-field,
    inconsistent, or mismatched evidence always returns a reason so the caller reruns the task's
    focused validators; absent evidence is never treated as a pass.

    Trust boundary (see `EVIDENCE_TRUST_BOUNDARY`): the record is unauthenticated controller state.
    This decision fails closed for every single-field tamper, but a fully consistent forged record
    cannot be distinguished from a genuine one without authenticated or append-only evidence, which
    this task deliberately does not implement.
    """
    if not isinstance(record, dict):
        return None, "no submit evidence recorded"
    if record.get("evidenceVersion") != EVIDENCE_VERSION:
        return None, "submit evidence version is missing or unsupported"
    unknown = sorted(set(record) - set(SUBMIT_EVIDENCE_FIELDS))
    if unknown:
        return None, "submit evidence has unknown fields: " + ", ".join(unknown)
    missing = sorted(set(SUBMIT_EVIDENCE_FIELDS) - set(record))
    if missing:
        return None, "submit evidence is incomplete: " + ", ".join(missing)
    if not isinstance(record.get("at"), str) or not record["at"]:
        return None, "submit evidence timestamp is missing"
    if record.get("actor") != task["implementationMode"]:
        return None, "submit evidence actor does not match the task implementation mode"
    if record.get("sourceFingerprint") != fingerprint:
        return None, "source fingerprint changed since submit"
    if record.get("changedFiles") != files:
        return None, "changed-file scope drifted since submit"
    plan = recorded_validator_plan(record)
    if plan is None:
        return None, "submit evidence has no complete passing validator record"
    if plan != validator_plan(task):
        return None, "required validator plan changed since submit"
    recomputed_fingerprint, recomputed_files = source_fingerprint()
    if recomputed_fingerprint != fingerprint or recomputed_files != files:
        return None, "source changed while the reuse decision was evaluated"
    return list(record["validators"]), None


def require_task_size(task, files, *, emit_warning=True):
    """Enforce the micro-task sizing contract on the caller's gathered non-state scope.

    Bands (identical to the `scope.budget` values the MCP delivery context advertises):

    - 1-3 non-state files: the target size for one tracked task, no output.
    - 4-5 non-state files: `TASK_SIZE_WARNING` on stderr, non-blocking, so `submit` still succeeds
      and the handoff carries the explicit justification.
    - more than 5 non-state files: `TASK_TOO_LARGE_SPLIT_REQUIRED`, raised before any validator runs
      or any controller state is written, so the task must be split first.

    `files` is the snapshot from `change_snapshot()` that the caller also fingerprints and persists;
    this function never re-gathers the scope, so the counted file set and the acted-upon file set are
    one list and a file that appears after the count cannot be recorded without being counted.

    Only this scope decides the verdict, so controller-owned state, generated views, and review
    reports never count toward the size.

    The hard verdict is applied by every call, but a command gates more than once: `submit` gates
    before and after its required validators, and `complete` gates before and after its reuse decision.
    A provisional call passes `emit_warning=False`, so the one `TASK_SIZE_WARNING` a command may emit
    is written by its authoritative call over the snapshot it fingerprints and persists. A warning-band
    scope that grows from 4 to 5 files while the validators run is therefore reported once, with the
    final counted scope, instead of the same count twice (P-WF-T05-D2).
    """
    count = len(files)
    if count > TASK_SIZE_HARD_SPLIT_ABOVE:
        raise TaskError(
            f"TASK_TOO_LARGE_SPLIT_REQUIRED: {task['id']} changes {count} non-state files; "
            f"task size target is {TASK_SIZE_TARGET} and the hard split threshold is "
            f"{TASK_SIZE_HARD_SPLIT_ABOVE}. Split the task before submission."
        )
    if count > TASK_SIZE_TARGET and emit_warning:
        print(
            f"TASK_SIZE_WARNING: {task['id']} changes {count} non-state files; target is "
            f"{TASK_SIZE_TARGET}, warning band is {TASK_SIZE_TARGET + 1}-{TASK_SIZE_WARNING_MAX}, "
            f"and only more than {TASK_SIZE_HARD_SPLIT_ABOVE} non-state files block submission.",
            file=sys.stderr,
        )


def require_allowed_scope(task, files):
    """Allowed-file check decided on the caller's gathered snapshot, never on a fresh gather."""
    disallowed = [file for file in files if not any(fnmatch.fnmatch(file, pattern) for pattern in task["allowedFiles"])]
    if disallowed:
        raise TaskError(f"{task['id']}: changed files outside allowedFiles: {', '.join(disallowed)}")


def enforce_scope(task, files, *, emit_size_warning=True):
    """Decide both scope checks on one gathered snapshot, never on a fresh gather.

    `files` must be the list that the caller will fingerprint and persist, so the allowedFiles verdict
    and the size verdict describe exactly the scope the controller acts on.

    `emit_size_warning` is passed through to `require_task_size` and is `False` for a command's
    provisional gate call: the allowedFiles verdict and the size hard block still apply there, but the
    warning-band message is left to the command's authoritative call, so one command emits at most one
    `TASK_SIZE_WARNING` and that message always describes the persisted snapshot (P-WF-T05-D2).
    """
    require_allowed_scope(task, files)
    require_task_size(task, files, emit_warning=emit_size_warning)


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
    next_parser.add_argument("--track", choices=[PLATFORM_TRACK], default=PLATFORM_TRACK)
    next_parser.add_argument("--check", action="store_true")
    list_parser = sub.add_parser("list")
    list_parser.add_argument("--track", choices=[PLATFORM_TRACK], default=PLATFORM_TRACK)
    branch_parser = sub.add_parser("branch")
    branch_parser.add_argument("--track", choices=[PLATFORM_TRACK], default=PLATFORM_TRACK)
    validate_parser = sub.add_parser("validate")
    validate_parser.add_argument("--sync", action="store_true")
    validate_parser.add_argument("--ignore-branch", action="store_true")
    fingerprint_parser = sub.add_parser("fingerprint")
    fingerprint_parser.add_argument("--base", choices=["dev", "main", "origin/dev", "origin/main"], default="dev")
    for command in ("start", "submit", "complete", "unblock"):
        action = sub.add_parser(command)
        action.add_argument("task_id")
        action.add_argument("--actor", required=True)
    reconcile = sub.add_parser("reconcile-merged")
    reconcile.add_argument("task_id")
    reconcile.add_argument("--actor", required=True)
    reconcile.add_argument("--pr", required=True, type=int)
    reconcile.add_argument("--merge-commit", required=True)
    reconcile.add_argument("--ci-run", required=True, type=int)
    reconcile.add_argument("--reason", required=True)
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
                print(render_task(next_task(data), PLATFORM_TRACK) if args.track else render_dashboard(data))
            return 0
        if args.cmd == "list":
            for task in data["tasks"]:
                print(f"{task['id']}\t{task['track']}\t{task['status']}\t{task['title']}")
            return 0
        if args.cmd == "branch":
            task = next_task(data)
            if not task:
                raise TaskError("no runnable PlatformInit task")
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
        if args.cmd == "fingerprint":
            base_ref, _ = resolve_base(args.base)
            fingerprint, files = source_fingerprint(args.base)
            print(f"base={base_ref or '<no-commits>'}")
            print(f"fingerprint={fingerprint}")
            print(f"files={len(files)}")
            for relative in files:
                print(f"file={relative}")
            return 0

        task = get_task(data, args.task_id)
        if args.cmd == "reconcile-merged":
            if task["status"] != "pending":
                raise TaskError(f"{task['id']} is {task['status']}, not pending")
            if args.actor != RELEASE:
                raise TaskError(f"{task['id']} reconciliation must be recorded by {RELEASE}")
            if not deps_done(task, data):
                raise TaskError(f"{task['id']} has incomplete dependencies")
            if not args.reason.strip():
                raise TaskError("reconciliation reason must not be empty")
            if len(args.merge_commit) != 40 or any(ch not in "0123456789abcdefABCDEF" for ch in args.merge_commit):
                raise TaskError("merge commit must be a full 40-character hexadecimal SHA")
            merged = subprocess.run(
                ["git", "merge-base", "--is-ancestor", args.merge_commit, "dev"],
                cwd=ROOT, text=True, capture_output=True,
            )
            if merged.returncode != 0:
                raise TaskError(f"{task['id']}: merge commit is not an ancestor of local dev")
            task["status"] = "done"
            task["workflow"] = {
                "reconciliation": {
                    "at": now(),
                    "actor": args.actor,
                    "kind": "merged_without_controller_lifecycle",
                    "pullRequest": args.pr,
                    "mergeCommit": args.merge_commit.lower(),
                    "ciRun": args.ci_run,
                    "reason": args.reason.strip(),
                    "limitations": (
                        "Historical reconciliation only: this record does not assert that the normal "
                        "implementation/review/security/release controller transitions occurred."
                    ),
                }
            }
            task.pop("blocker", None)
            save(data)
        elif args.cmd == "start":
            if task["status"] != "pending":
                raise TaskError(f"{task['id']} is {task['status']}, not pending")
            if active_task(data):
                raise TaskError("platform already has an active task")
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
            files, fingerprint = change_snapshot()
            # Provisional gate: it still hard-blocks above the split threshold (fail-fast, before any
            # validator runs), but it defers the warning-band message to the authoritative snapshot
            # below so one `submit` can never emit two `TASK_SIZE_WARNING` lines (P-WF-T05-D2).
            enforce_scope(task, files, emit_size_warning=False)
            validators = run_validators(task)
            # Validators can touch the tree, so the snapshot that is fingerprinted and persisted is
            # gathered once more after they ran and is re-decided on that exact list. The size gate,
            # the fingerprint, and the recorded evidence therefore always describe one scope: a file
            # that appears after the count can never be recorded without being counted too.
            final_files, final_fingerprint = change_snapshot()
            # This authoritative decision always runs, also when the scope did not change, so the one
            # warning a submit may emit always reports the scope that is about to be persisted.
            enforce_scope(task, final_files)
            files, fingerprint = final_files, final_fingerprint
            task.setdefault("workflow", {})["submit"] = {
                "evidenceVersion": EVIDENCE_VERSION,
                "at": now(),
                "actor": args.actor,
                "validators": validators,
                "sourceFingerprint": fingerprint,
                "changedFiles": files,
            }
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
            files, fingerprint = change_snapshot()
            # Provisional gate: hard verdict only, with the warning-band message deferred to this
            # command's authoritative snapshot (see `enforce_scope`), so `complete` emits at most one
            # `TASK_SIZE_WARNING` even when the reuse decision rejects the submitted evidence and the
            # scope is gated again in the rerun path below (P-WF-T05-D2).
            enforce_scope(task, files, emit_size_warning=False)
            previous_status = task["status"]
            validators, reason = reusable_submit_evidence(task, workflow.get("submit"), fingerprint, files)
            reused = validators is not None
            if reused:
                # Persisted-record confirmation, taken as late as practical: read the fingerprint once
                # more immediately before the completion record is built, and persist only this reading
                # together with the exact fingerprint inputs it was taken over. Drift observed here
                # falls through to the focused rerun below, so reused evidence is never recorded for
                # source that some earlier reading described.
                confirmation, confirmation_files = source_fingerprint()
                if (confirmation, confirmation_files) != (fingerprint, files):
                    reused = False
                    reason = "source changed while the reuse decision was evaluated"
            if reused:
                fingerprint, files = confirmation, confirmation_files
                decision = "reused submit evidence: fingerprint and validator plan unchanged"
                # The confirmed list is this command's authoritative scope and is the same list the
                # provisional gate above already checked, so emitting the size warning here is what
                # keeps `complete` at exactly one warning per command.
                require_task_size(task, files)
            else:
                validators = run_validators(task)
                decision = f"reran required focused validators: {reason}"
                # The rerun path persists a freshly fingerprinted scope, so that scope must pass the
                # same gate before it can back a `done` record.
                files, fingerprint = change_snapshot()
                enforce_scope(task, files)
            workflow["complete"] = {
                "evidenceVersion": EVIDENCE_VERSION,
                "at": now(),
                "actor": args.actor,
                "validators": validators,
                "sourceFingerprint": fingerprint,
                "changedFiles": files,
                "confirmedFingerprint": fingerprint,
                "confirmedFiles": files,
                "reusedSubmitEvidence": reused,
                "evidenceDecision": decision,
                "trustBoundary": EVIDENCE_TRUST_BOUNDARY,
            }
            task["status"] = "done"
            task.pop("blocker", None)
            save(data)
            # Post-persistence re-verification. The confirmation above is not atomic with `save()`: a
            # relevant source file can still change in the residual window between that confirmation
            # read and the atomic replacement of `tasks/tracker.json`. Recompute now and, when the
            # source no longer matches the recorded confirmation, fail loudly and repair controller
            # state instead of leaving a `done` task backed by stale reused evidence. The window after
            # this read cannot be closed without source locking or filesystem snapshot semantics, which
            # are deliberately out of scope (see docs/roo-lab/PLATFORM_WORKFLOW_REFACTOR.md).
            persisted_fingerprint, persisted_files = source_fingerprint()
            if (persisted_fingerprint, persisted_files) != (fingerprint, files):
                task["status"] = previous_status
                workflow.pop("complete", None)
                save(data)
                raise TaskError(
                    f"{task['id']}: source changed after the completion record was confirmed "
                    f"(confirmed {fingerprint[:12]}, now {persisted_fingerprint[:12]}); reverted to "
                    f"{previous_status} instead of recording a done task with stale reused evidence - "
                    "rerun complete to revalidate the focused validators"
                )
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
