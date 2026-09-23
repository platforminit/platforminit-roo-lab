#!/usr/bin/env python3
"""Deterministic, bounded memory retrieval for PlatformInit Zoo Code.

Memory is advisory context only. It never owns task state; tasks/tracker.json remains authoritative.

Two layers are supported:
- memory/framework/core.jsonl: reusable framework lessons shipped with the framework.
- memory/project/records.jsonl: append-only project lessons distilled from accepted evidence.

The MCP-facing retrieval path is read-only. Project-memory writes are available only through the
repository-local CLI and are intended to happen in reviewed source changes, never as hidden runtime state.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
FRAMEWORK_MEMORY = ROOT / "memory" / "framework" / "core.jsonl"
PROJECT_MEMORY = ROOT / "memory" / "project" / "records.jsonl"

MEMORY_VERSION = 1
DEFAULT_MAX_ITEMS = 6
HARD_MAX_ITEMS = 12
MAX_QUERY_LENGTH = 512
MAX_SUMMARY_LENGTH = 1200

ALLOWED_SCOPES = {"framework", "project"}
ALLOWED_STATUS = {"active", "deprecated", "historical"}
ID_RE = re.compile(r"^[a-z0-9][a-z0-9._:-]{2,127}$")
TOKEN_RE = re.compile(r"[a-z0-9][a-z0-9_.:/-]*", re.IGNORECASE)


class MemoryError(ValueError):
    pass


def _bounded_text(value: object, *, field: str, maximum: int, allow_empty: bool = True) -> str:
    if not isinstance(value, str):
        raise MemoryError(f"{field} must be a string")
    text = value.strip()
    if not allow_empty and not text:
        raise MemoryError(f"{field} must not be empty")
    if len(text) > maximum:
        raise MemoryError(f"{field} exceeds maximum length")
    return text


def validate_max_items(value: object | None) -> int:
    if value is None:
        return DEFAULT_MAX_ITEMS
    if isinstance(value, bool) or not isinstance(value, int):
        raise MemoryError("maxItems must be an integer")
    return min(max(value, 1), HARD_MAX_ITEMS)


def _normalize_tags(value: object) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise MemoryError("tags must be an array of strings")
    tags = sorted({item.strip().lower() for item in value if item.strip()})
    if len(tags) > 16:
        raise MemoryError("tags exceeds maximum item count")
    if any(len(tag) > 64 for tag in tags):
        raise MemoryError("tag exceeds maximum length")
    return tags


def validate_record(raw: object, *, expected_scope: str | None = None) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise MemoryError("memory record must be an object")
    allowed = {
        "id", "scope", "type", "component", "task", "summary", "tags",
        "status", "sources", "createdFrom", "supersedes",
    }
    unknown = set(raw) - allowed
    if unknown:
        raise MemoryError("memory record has unsupported fields")

    record_id = _bounded_text(raw.get("id"), field="id", maximum=128, allow_empty=False)
    if not ID_RE.fullmatch(record_id):
        raise MemoryError("id has invalid format")

    scope = _bounded_text(raw.get("scope"), field="scope", maximum=16, allow_empty=False).lower()
    if scope not in ALLOWED_SCOPES:
        raise MemoryError("scope must be framework or project")
    if expected_scope is not None and scope != expected_scope:
        raise MemoryError(f"scope must be {expected_scope}")

    summary = _bounded_text(raw.get("summary"), field="summary", maximum=MAX_SUMMARY_LENGTH, allow_empty=False)
    record_type = _bounded_text(raw.get("type", "lesson"), field="type", maximum=64, allow_empty=False)
    component = _bounded_text(raw.get("component", ""), field="component", maximum=128)
    task = _bounded_text(raw.get("task", ""), field="task", maximum=128)
    status = _bounded_text(raw.get("status", "active"), field="status", maximum=16, allow_empty=False).lower()
    if status not in ALLOWED_STATUS:
        raise MemoryError("status must be active, deprecated, or historical")

    tags = _normalize_tags(raw.get("tags"))

    sources_raw = raw.get("sources", raw.get("createdFrom", []))
    if sources_raw is None:
        sources_raw = []
    if not isinstance(sources_raw, list) or not all(isinstance(item, str) for item in sources_raw):
        raise MemoryError("sources must be an array of strings")
    sources = [item.strip() for item in sources_raw if item.strip()]
    if len(sources) > 12 or any(len(item) > 240 for item in sources):
        raise MemoryError("sources exceed bounds")

    supersedes = raw.get("supersedes", [])
    if supersedes is None:
        supersedes = []
    if not isinstance(supersedes, list) or not all(isinstance(item, str) for item in supersedes):
        raise MemoryError("supersedes must be an array of strings")
    if len(supersedes) > 12:
        raise MemoryError("supersedes exceeds maximum item count")

    return {
        "id": record_id,
        "scope": scope,
        "type": record_type,
        "component": component,
        "task": task,
        "summary": summary,
        "tags": tags,
        "status": status,
        "sources": sources,
        "supersedes": supersedes,
    }


def load_jsonl(path: Path, *, expected_scope: str) -> list[dict[str, Any]]:
    if not path.is_file():
        return []
    records: list[dict[str, Any]] = []
    seen: set[str] = set()
    for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            raw = json.loads(line)
            record = validate_record(raw, expected_scope=expected_scope)
        except (json.JSONDecodeError, MemoryError) as exc:
            raise MemoryError(f"invalid memory record at {path.name}:{line_number}") from exc
        if record["id"] in seen:
            raise MemoryError(f"duplicate memory id in {path.name}")
        seen.add(record["id"])
        records.append(record)
    return records


def _tokens(text: str) -> set[str]:
    return {token.lower() for token in TOKEN_RE.findall(text)}


def _score(record: dict[str, Any], query_tokens: set[str], task_id: str, component: str) -> int:
    if record["status"] != "active":
        return -1000
    score = 0
    record_tokens = _tokens(" ".join([
        record["summary"],
        record["type"],
        record["component"],
        record["task"],
        " ".join(record["tags"]),
    ]))
    score += len(query_tokens & record_tokens) * 3
    if task_id and record["task"] == task_id:
        score += 12
    if component and record["component"].lower() == component.lower():
        score += 8
    if record["scope"] == "project":
        score += 1
    return score


def get_relevant_memory(
    *,
    query: object = "",
    task_id: object = "",
    component: object = "",
    max_items: object | None = None,
) -> dict[str, Any]:
    query_text = _bounded_text(query, field="query", maximum=MAX_QUERY_LENGTH)
    task_text = _bounded_text(task_id, field="taskId", maximum=128)
    component_text = _bounded_text(component, field="component", maximum=128)
    limit = validate_max_items(max_items)

    framework = load_jsonl(FRAMEWORK_MEMORY, expected_scope="framework")
    project = load_jsonl(PROJECT_MEMORY, expected_scope="project")
    all_records = framework + project

    query_tokens = _tokens(" ".join([query_text, task_text, component_text]))
    ranked = sorted(
        (
            (_score(record, query_tokens, task_text, component_text), record)
            for record in all_records
        ),
        key=lambda item: (-item[0], item[1]["scope"], item[1]["id"]),
    )

    # With no explicit query, return a small active baseline rather than the whole memory corpus.
    selected = [
        record for score, record in ranked
        if score >= (0 if not query_tokens else 1)
    ][:limit]

    return {
        "memoryVersion": MEMORY_VERSION,
        "authoritativeTaskSource": "tasks/tracker.json",
        "advisoryOnly": True,
        "itemCount": len(selected),
        "items": selected,
    }


def append_project_record(record: object) -> dict[str, Any]:
    normalized = validate_record(record, expected_scope="project")
    existing = load_jsonl(PROJECT_MEMORY, expected_scope="project")
    if any(item["id"] == normalized["id"] for item in existing):
        raise MemoryError("project memory id already exists")

    PROJECT_MEMORY.parent.mkdir(parents=True, exist_ok=True)
    with PROJECT_MEMORY.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(normalized, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")
    return normalized


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="PlatformInit Zoo project-memory helper")
    sub = parser.add_subparsers(dest="command", required=True)

    get_parser = sub.add_parser("get", help="retrieve bounded relevant memory")
    get_parser.add_argument("--query", default="")
    get_parser.add_argument("--task-id", default="")
    get_parser.add_argument("--component", default="")
    get_parser.add_argument("--max-items", type=int, default=DEFAULT_MAX_ITEMS)

    add_parser = sub.add_parser("add-project", help="append one reviewed project-memory record from JSON")
    add_parser.add_argument("json_file")

    args = parser.parse_args(argv)
    try:
        if args.command == "get":
            value = get_relevant_memory(
                query=args.query,
                task_id=args.task_id,
                component=args.component,
                max_items=args.max_items,
            )
        else:
            raw = json.loads(Path(args.json_file).read_text(encoding="utf-8"))
            value = append_project_record(raw)
    except (MemoryError, json.JSONDecodeError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(value, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
