#!/usr/bin/env python3
"""Deterministic, bounded memory retrieval for PlatformInit Zoo Code.

Memory is advisory context only. It never owns task state; tasks/tracker.json remains authoritative.

Two layers are supported:
- memory/framework/core.jsonl: reusable framework lessons shipped with the framework.
- memory/project/records.jsonl: append-only project lessons distilled from accepted evidence.

The MCP-facing retrieval path is read-only. Project-memory writes are available only through the
repository-local CLI and are intended to happen in reviewed source changes, never as hidden runtime state.

Ranking invariant: a record is eligible for a non-empty query only when it has lexical overlap or an
exact task/component match. The project-scope bonus is a bounded tie-break, so an unrelated project
record can never be returned for a query it does not actually match.

Supersession invariant: an ``active`` record suppresses every record id it declares in ``supersedes``,
transitively along the chain, before ranking happens. Suppression is resolved deterministically from
ids alone and never depends on file, line, or dict order, so a superseded fact cannot reappear through
bounds, tie-breaks, or the empty-query baseline. Non-active records never suppress anything, and a
supersession cycle, a dangling target, or any supersedes entry that is not a well-formed record id
fails the whole retrieval closed instead of silently leaving obsolete memory eligible.
"""
from __future__ import annotations

import argparse
import heapq
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
MAX_SUPERSEDES_TARGETS = 12

# Ranking weights. Lexical overlap and exact task/component matches define relevance; the
# project-scope bonus is a bounded tie-break signal only and never an eligibility signal.
LEXICAL_OVERLAP_WEIGHT = 3
TASK_EXACT_BONUS = 12
COMPONENT_EXACT_BONUS = 8
PROJECT_SCOPE_BONUS = 1

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

    supersedes_raw = raw.get("supersedes", [])
    if supersedes_raw is None:
        supersedes_raw = []
    if not isinstance(supersedes_raw, list) or not all(
        isinstance(item, str) for item in supersedes_raw
    ):
        raise MemoryError("supersedes must be an array of strings")
    if len(supersedes_raw) > MAX_SUPERSEDES_TARGETS:
        raise MemoryError("supersedes exceeds maximum item count")
    supersedes: list[str] = []
    for item in supersedes_raw:
        target = item.strip()
        if not target:
            raise MemoryError("supersedes must not contain empty values")
        if not ID_RE.fullmatch(target):
            raise MemoryError("supersedes has invalid id format")
        if target == record_id:
            raise MemoryError("a memory record must not supersede itself")
        supersedes.append(target)
    # Sorted and deduplicated so the suppression graph never depends on authoring order.
    supersedes = sorted(set(supersedes))

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


def _record_tokens(record: dict[str, Any]) -> set[str]:
    return _tokens(" ".join([
        record["summary"],
        record["type"],
        record["component"],
        record["task"],
        " ".join(record["tags"]),
    ]))


def _relevance_and_scope_bonus(
    record: dict[str, Any],
    query_tokens: set[str],
    task_id: str,
    component: str,
) -> tuple[int, int]:
    """Return ``(relevance, scope_bonus)`` for one record.

    Relevance counts lexical overlap and exact task/component matches only, so it is the sole
    eligibility signal for a non-empty query. The project-scope bonus is deliberately reported
    separately and applies only as a bounded tie-break among equally relevant records.
    """
    relevance = len(query_tokens & _record_tokens(record)) * LEXICAL_OVERLAP_WEIGHT
    if task_id and record["task"] == task_id:
        relevance += TASK_EXACT_BONUS
    if component and record["component"].lower() == component.lower():
        relevance += COMPONENT_EXACT_BONUS
    scope_bonus = PROJECT_SCOPE_BONUS if record["scope"] == "project" else 0
    return relevance, scope_bonus


def _supersession_graph(
    records: list[dict[str, Any]],
) -> tuple[dict[str, dict[str, Any]], dict[str, tuple[str, ...]]]:
    """Return ``(by_id, adjacency)`` for the combined memory corpus.

    Ids must be unique across framework and project memory, because a duplicated id would make both
    replacement and suppression ambiguous. Every adjacency list is id-sorted and deduplicated, so the
    graph is independent of load order.
    """
    by_id: dict[str, dict[str, Any]] = {}
    for record in records:
        record_id = record["id"]
        if record_id in by_id:
            raise MemoryError(f"duplicate memory id across memory scopes: {record_id}")
        by_id[record_id] = record
    adjacency = {
        record_id: tuple(sorted(set(record.get("supersedes") or ())))
        for record_id, record in sorted(by_id.items())
    }
    return by_id, adjacency


def _assert_supersession_integrity(
    by_id: dict[str, dict[str, Any]],
    adjacency: dict[str, tuple[str, ...]],
) -> None:
    """Fail closed on a malformed or cyclic supersession graph.

    A dangling target, a self-reference, or a cycle would either silently leave obsolete memory
    eligible or force an arbitrary chain order, so retrieval refuses the whole corpus instead of
    returning a re-ranked or partially suppressed answer.
    """
    for record_id in sorted(adjacency):
        for target in adjacency[record_id]:
            if target == record_id:
                raise MemoryError(f"memory record supersedes itself: {record_id}")
            if target not in by_id:
                raise MemoryError(f"supersedes references unknown memory id: {target}")

    # Kahn's algorithm over id-sorted edges: cycle detection with deterministic traversal order.
    indegree = {record_id: 0 for record_id in adjacency}
    for targets in adjacency.values():
        for target in targets:
            indegree[target] += 1
    ready = [record_id for record_id, degree in indegree.items() if degree == 0]
    heapq.heapify(ready)
    resolved = 0
    while ready:
        record_id = heapq.heappop(ready)
        resolved += 1
        for target in adjacency[record_id]:
            indegree[target] -= 1
            if indegree[target] == 0:
                heapq.heappush(ready, target)
    if resolved != len(adjacency):
        raise MemoryError("supersession cycle detected in memory corpus")


def superseded_record_ids(records: list[dict[str, Any]]) -> set[str]:
    """Return the deterministic set of record ids suppressed by active replacements.

    Only ``active`` records suppress, so historical/deprecated records stay non-active context and can
    never hide an active fact. Suppression follows the chain transitively, including through an
    intermediate record that is itself replaced, so a superseded fact cannot reappear by any path.
    """
    by_id, adjacency = _supersession_graph(records)
    _assert_supersession_integrity(by_id, adjacency)

    suppressed: set[str] = set()
    frontier = sorted(
        target
        for record_id in sorted(by_id)
        if by_id[record_id]["status"] == "active"
        for target in adjacency[record_id]
    )
    while frontier:
        record_id = frontier.pop()
        if record_id in suppressed:
            continue
        suppressed.add(record_id)
        frontier.extend(adjacency[record_id])
    return suppressed


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
    # Resolve supersession across the whole corpus and apply it before ranking, so no bound,
    # tie-break, or baseline path can return a superseded fact.
    suppressed_ids = superseded_record_ids(all_records)

    query_tokens = _tokens(" ".join([query_text, task_text, component_text]))
    ranked: list[tuple[int, int, dict[str, Any]]] = []
    for record in all_records:
        if record["status"] != "active" or record["id"] in suppressed_ids:
            continue
        relevance, scope_bonus = _relevance_and_scope_bonus(
            record, query_tokens, task_text, component_text
        )
        ranked.append((relevance, scope_bonus, record))
    ranked.sort(key=lambda item: (-item[0], -item[1], item[2]["scope"], item[2]["id"]))

    # A non-empty query requires real relevance: the project-scope tie-break bonus alone must never
    # make a zero-overlap record eligible. With no query tokens, return a small active baseline
    # instead of the whole memory corpus.
    if query_tokens:
        selected = [record for relevance, _bonus, record in ranked if relevance > 0][:limit]
    else:
        selected = [record for _relevance, _bonus, record in ranked][:limit]

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
    if normalized["supersedes"]:
        # Fail at authoring time rather than persisting a dangling edge that later fails retrieval closed.
        known = {item["id"] for item in load_jsonl(FRAMEWORK_MEMORY, expected_scope="framework")}
        known.update(item["id"] for item in existing)
        unknown = sorted(set(normalized["supersedes"]) - known)
        if unknown:
            raise MemoryError("supersedes references unknown memory id")

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
