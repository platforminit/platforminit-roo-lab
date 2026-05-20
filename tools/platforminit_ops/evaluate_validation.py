#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
import sys


def find_latest_report(base_dir: pathlib.Path) -> pathlib.Path:
    matches = sorted(base_dir.rglob("validate-host-latest.json")) + sorted(base_dir.rglob("validate-host-*.json"))
    if not matches:
        raise SystemExit(f"Missing validation JSON report under {base_dir}")
    # prefer latest alias, else lexical last timestamped file
    latest_alias = [m for m in matches if m.name == "validate-host-latest.json"]
    return latest_alias[-1] if latest_alias else matches[-1]


def main() -> int:
    base_dir = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "baseline-artifacts/reports")
    report_json = find_latest_report(base_dir)
    with report_json.open("r", encoding="utf-8") as fh:
        payload = json.load(fh)

    summary = payload.get("summary") or {}
    pass_count = int(summary.get("pass", 0))
    warn_count = int(summary.get("warn", 0))
    fail_count = int(summary.get("fail", 999))

    print(f"Validation JSON: {report_json}")
    print(json.dumps(payload, indent=2))
    print(f"Validation summary: pass={pass_count} warn={warn_count} fail={fail_count}")

    md_report = report_json.with_suffix(".md")
    if md_report.exists():
        print("--- Validation markdown report ---")
        print(md_report.read_text(encoding="utf-8"))

    return 0 if fail_count == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
