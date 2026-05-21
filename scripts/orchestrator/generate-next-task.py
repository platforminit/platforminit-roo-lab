#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content.rstrip() + "\n", encoding="utf-8")


def bullet(items: list[str]) -> str:
    if not items:
        return "- Not specified yet."
    return "\n".join(f"- {item}" for item in items)


def task_goal(task: dict[str, Any]) -> str:
    return (
        task.get("goal")
        or task.get("description")
        or task.get("title")
        or task.get("id")
        or "No goal defined."
    )


def render_next(track: str, task: dict[str, Any]) -> str:
    deps = task.get("depends_on_platform_tasks", [])
    same_track_deps = task.get("depends_on", [])
    acceptance = task.get("acceptance", ["Acceptance criteria must be refined during task execution."])
    forbidden = task.get("forbidden", ["Do not target production/customer scope unless explicitly approved."])

    if deps:
        shared_foundation = "This task consumes shared PlatformInit foundation task(s): " + ", ".join(deps)
    else:
        shared_foundation = "This task does not consume a shared platform dependency."

    if same_track_deps:
        dependency_line = "Same-track dependency: " + ", ".join(same_track_deps)
    else:
        dependency_line = "No same-track dependency is declared for this current pointer."

    lines = [
        f"# NEXT TASK — {track}",
        "",
        "## Task",
        "",
        f"- Track: `{track}`",
        f"- Task ID: `{task.get('id', '')}`",
        f"- Chapter: `{task.get('chapter', '')}`",
        f"- Title: {task.get('title', '')}",
        f"- Branch: `{task.get('branch', '')}`",
        f"- Scope: `{task.get('scope', '')}`",
        "",
        "## Goal",
        "",
        task_goal(task),
        "",
        "## Shared foundation model",
        "",
        shared_foundation,
        "",
        dependency_line,
        "",
        "## Acceptance criteria",
        "",
        bullet(acceptance),
        "",
        "## Forbidden actions",
        "",
        "- Do not resurrect deprecated CH05 directions as active work.",
        "- Do not expose secret values.",
        "- Do not use Windows shell, PowerShell, CMD, Git Bash, or MobaXterm for Roo execution.",
        bullet(forbidden),
        "",
        "## Required startup",
        "",
        "```bash",
        "cd /mnt/d/SYSADMIN/platforminit-roo-lab",
        f"./scripts/orchestrator/start-next-task.sh --track {track}",
        "```",
        "",
        "## Roo entrypoint",
        "",
        "```text",
        f"Read tasks/active/{track}/NEXT_TASK.md and execute the active task exactly as described.",
        "```",
        "",
        "## Native role handoff",
        "",
        "PlatformInit roles must use native Roo `switch_mode` handoff.",
        "",
        "Manual next-prompt printing is allowed only if native `switch_mode` is unavailable or blocked, and the role must explicitly report:",
        "",
        "```text",
        "SWITCH_MODE_UNAVAILABLE_FALLBACK_USED",
        "```",
    ]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--track", choices=["platform", "n8n"], required=True)
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()

    roadmap = load_json(ROOT / "tasks" / "roadmap" / f"{args.track}.json")
    status = load_json(ROOT / "tasks" / "status" / f"{args.track}.json")

    current = status["current_pointer"]
    tasks = {task["id"]: task for task in roadmap["tasks"]}
    if current not in tasks:
        raise SystemExit(f"current_pointer not found in roadmap: {current}")

    content = render_next(args.track, tasks[current])
    out = ROOT / "tasks" / "active" / args.track / "NEXT_TASK.md"

    if args.write:
        write_text(out, content)
        print(f"wrote {out.relative_to(ROOT)}")
    else:
        print(content)


if __name__ == "__main__":
    main()
