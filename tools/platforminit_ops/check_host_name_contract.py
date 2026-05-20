#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys

FORBIDDEN = "platforminit-" + "development-01"
EXPECTED = "platforminit-dev-01"
SKIP_DIRS = {".git", "node_modules", ".venv", "venv", "dist", "artifacts"}


def iter_files(root: pathlib.Path):
    for path in root.rglob("*"):
        if not path.is_file():
            continue
        if any(part in SKIP_DIRS for part in path.parts):
            continue
        yield path


def main() -> int:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    hits: list[tuple[pathlib.Path, int, str]] = []
    for path in iter_files(root):
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        for lineno, line in enumerate(lines, 1):
            if FORBIDDEN in line:
                hits.append((path, lineno, line.strip()))

    if hits:
        print("Host naming contract violation detected.", file=sys.stderr)
        print(f"Forbidden host name: {FORBIDDEN}", file=sys.stderr)
        print(f"Expected host name:  {EXPECTED}", file=sys.stderr)
        for path, lineno, line in hits:
            print(f"{path}:{lineno}: {line}", file=sys.stderr)
        return 2

    print(f"Host naming contract OK: {EXPECTED}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
