#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from datetime import datetime, timezone


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def save_json(path, data):
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def render_next_task(track, task):
    allowed = "\n".join(f"- `{p}`" for p in task.get("allowed_files", []))
    forbidden = "\n".join(f"- {x}" for x in task.get("forbidden", []))
    return f"""# Next Active Task: {task['id']} - {task['title']}

## Track

`{track}`

## Chapter

`{task['chapter']}`

## Branch

`{task['branch']}`

## Preferred mode

`{task.get('mode', 'PlatformInit Orchestrator')}`

## Goal

{task['goal']}

## Human entrypoint

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
./scripts/orchestrator/start-next-task.sh --track {track}
code .
```

Then in Roo:

```text
Read tasks/active/{track}/NEXT_TASK.md and execute the active task exactly as described.
```

## Required startup checks

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
./scripts/lib/require-wsl-runtime.sh
git branch --show-current
git status --short
```

Expected branch:

```text
{task['branch']}
```

## Allowed files / paths

{allowed if allowed else '- No file allowlist declared; stop and ask for task update.'}

## Forbidden actions

{forbidden if forbidden else '- Do not perform destructive or infrastructure-mutating actions unless explicitly approved.'}

## Native Roo role handoff

Use the native Roo `switch_mode` contract.

Manual next-prompt printing is allowed only when native `switch_mode` is unavailable or blocked. If fallback is used, explicitly report:

```text
SWITCH_MODE_UNAVAILABLE_FALLBACK_USED
```

## Completion rule

At closeout, Release Manager must run:

```bash
./scripts/orchestrator/close-current-task.sh --track {track} --task {task['id']}
```

This marks the task complete and regenerates the next task for this track.
"""


def find_next(track):
    roadmap = load_json(f"tasks/roadmap/{track}.json")
    status_path = Path(f"tasks/status/{track}.json")
    if not status_path.exists():
        save_json(status_path, {
            "schema_version": "1.0",
            "track": track,
            "updated_at": datetime.now(timezone.utc).isoformat(),
            "tasks": [{"id": t["id"], "chapter": t["chapter"], "title": t["title"], "branch": t["branch"], "is_completed": False} for t in roadmap["tasks"]],
        })
    status = load_json(status_path)
    completed = {t["id"] for t in status["tasks"] if t.get("is_completed")}
    for task in roadmap["tasks"]:
        if task["id"] not in completed:
            return task
    return None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--track", required=True, choices=["platform", "n8n"])
    parser.add_argument("--print-branch", action="store_true")
    parser.add_argument("--write", action="store_true")
    args = parser.parse_args()
    task = find_next(args.track)
    if task is None:
        if args.print_branch:
            print("")
        else:
            print(f"No remaining tasks for track: {args.track}")
        return
    if args.print_branch:
        print(task["branch"])
        return
    content = render_next_task(args.track, task)
    out = Path(f"tasks/active/{args.track}/NEXT_TASK.md")
    if args.write:
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_text(content, encoding="utf-8")
        print(f"wrote {out}")
    else:
        print(content)


if __name__ == "__main__":
    main()
