#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TASKCTL = ROOT / "tools" / "task_controller" / "taskctl.py"


def main() -> int:
    parser = argparse.ArgumentParser(description="Compatibility wrapper for the canonical task controller")
    parser.add_argument("--track", required=True, choices=["platform", "n8n"])
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--print-branch", action="store_true")
    args = parser.parse_args()

    if args.print_branch:
        command = [sys.executable, str(TASKCTL), "branch", "--track", args.track]
    else:
        command = [sys.executable, str(TASKCTL), "next", "--track", args.track]
    return subprocess.run(command, cwd=ROOT).returncode


if __name__ == "__main__":
    raise SystemExit(main())
