#!/usr/bin/env python3
"""Compatibility wrapper for the canonical PlatformInit task controller.

The PlatformInit next-task flow is PlatformInit-only: ``--track`` accepts the
``platform`` track only. `n8n` has its own roadmap and task registry and is
rejected with a clear non-zero error instead of selecting a non-PlatformInit
queue.
"""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TASKCTL = ROOT / "tools" / "task_controller" / "taskctl.py"
SUPPORTED_TRACKS = ("platform",)
DETACHED_TRACKS = ("n8n",)
DETACHED_TRACK_MESSAGE = (
    "--track n8n is not an active PlatformInit track: n8n work has its own roadmap and "
    "task registry and is not selectable through the PlatformInit next-task flow."
)


def parse_cli(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="generate-next-task.py",
        description="Compatibility wrapper for the canonical task controller (platform track only)",
    )
    parser.add_argument(
        "--track",
        required=True,
        metavar="TRACK",
        help="PlatformInit track to select; only 'platform' is supported.",
    )
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--print-branch", action="store_true")
    args = parser.parse_args(argv)

    if args.track in DETACHED_TRACKS:
        parser.error(DETACHED_TRACK_MESSAGE)
    if args.track not in SUPPORTED_TRACKS:
        parser.error(
            "unsupported track {!r}: PlatformInit supports only {}".format(
                args.track, ", ".join(SUPPORTED_TRACKS)
            )
        )
    return args


def main() -> int:
    args = parse_cli(sys.argv[1:])

    if args.print_branch:
        command = [sys.executable, str(TASKCTL), "branch", "--track", args.track]
    else:
        command = [sys.executable, str(TASKCTL), "next", "--track", args.track]
    return subprocess.run(command, cwd=ROOT).returncode


if __name__ == "__main__":
    raise SystemExit(main())
