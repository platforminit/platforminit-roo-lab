#!/usr/bin/env python3
"""Deterministic, bounded memory retrieval for PlatformInit Zoo Code.

Memory is advisory context only. It never owns task state; tasks/tracker.json remains authoritative.

Two layers are supported:
- memory/framework/core.jsonl: reusable framework lessons shipped with the framework.
- memory/project/records.jsonl: append-only project lessons distilled from accepted evidence.

The MCP-facing retrieval path is read-only. Project-memory writes are available only through the
repository-local CLI and are intended to happen in reviewed source changes, never as hidden runtime state.

Project memory is filled in two explicit steps. A completed, fully approved task may stage bounded
candidates in ``memory/project/candidates.jsonl``, and only an explicit promotion copies a candidate
into retrieval-visible ``memory/project/records.jsonl``. A candidate is never retrieval context.

Ranking invariant: a record is eligible for a non-empty query only when it has lexical overlap or an
exact task/component match. The project-scope bonus is a bounded tie-break, so an unrelated project
record can never be returned for a query it does not actually match.

Supersession invariant: an ``active`` record suppresses every record id it declares in ``supersedes``,
transitively along the chain, before ranking happens. Suppression is resolved deterministically from
ids alone and never depends on file, line, or dict order, so a superseded fact cannot reappear through
bounds, tie-breaks, or the empty-query baseline. Non-active records never suppress anything, and a
supersession cycle, a dangling target, or any supersedes entry that is not a well-formed record id
fails the whole retrieval closed instead of silently leaving obsolete memory eligible.

Project-memory lifecycle: candidates and promotion (P-WF-T14)
------------------------------------------------------------
1. Candidate: only a completed task with an OpenAI ``approve`` verdict and an OWASP ``clear`` verdict
   may emit bounded candidates from already committed approved evidence. A candidate must carry full
   provenance (task id, release stage, source commit, both verdicts, approved evidence paths, and an
   allowed emitter), must reference approved evidence as its sources, and is stored in
   ``memory/project/candidates.jsonl``.
2. Promotion: promotion re-validates the candidate and appends it as an ``active`` project record in
   ``memory/project/records.jsonl``. Promotion is explicit, idempotent, and refused for a duplicate id
   or duplicate normalized content.

Safety and authority invariants:
- Raw transient logs, absolute or traversing paths, key material, and secret-looking values or paths
  are rejected before anything is written, so secrets and terminal noise never enter project memory.
- Retrieval loads framework memory plus promoted project records only. The candidate file is never
  read by ``get_relevant_memory``, so an unpromoted candidate cannot be returned, not even at the hard
  cap.
- Memory, including promoted memory, stays advisory context. ``tasks/tracker.json`` and ``taskctl``
  remain the only authoritative delivery state, and this lifecycle grants no new authority over it.
- The candidate schema and the promotion gate are the seam a later evidence-distillation feature may
  reuse; distillation may stage candidates but must still pass the same provenance and promotion rules.
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

# v2 adds optional per-record release provenance plus the candidate/promotion lifecycle. Retrieval
# response keys are unchanged; promoted records may additionally carry a "provenance" object.
MEMORY_VERSION = 2
DEFAULT_MAX_ITEMS = 6
HARD_MAX_ITEMS = 12
MAX_QUERY_LENGTH = 512
MAX_SUMMARY_LENGTH = 1200
MAX_SUPERSEDES_TARGETS = 12

# Project-memory lifecycle (P-WF-T14). Candidates are staged and advisory; only promotion makes a
# candidate retrieval-visible, and neither step owns task state.
PROJECT_CANDIDATES = ROOT / "memory" / "project" / "candidates.jsonl"
CANDIDATE_STATUS = "candidate"
PROMOTION_STAGE = "release"
REQUIRED_REVIEW_VERDICT = "approve"
REQUIRED_SECURITY_VERDICT = "clear"
MAX_CANDIDATE_EVIDENCE_PATHS = 8
MAX_CANDIDATES_PER_TASK = 5
APPROVED_EVIDENCE_PREFIXES = ("docs/reviews/", "docs/security-reviews/", "docs/roo-lab/", "tasks/")
ALLOWED_EMITTERS = ("platforminit-release-manager", "evidence-distillation")
COMMIT_RE = re.compile(r"^[0-9a-f]{7,40}$")
TASK_ID_RE = re.compile(r"^[A-Z][A-Z0-9]*(?:[.-][A-Z0-9]+)*$")
# Transient output, local secret locations, key material, and traversal never become memory sources.
UNSAFE_PATH_RE = re.compile(
    r"^(?:/|~|[A-Za-z]:[\\/])"
    r"|(?:^|/)\.\.(?:/|$)"
    r"|(?:^|/)\.local_secrets(?:/|$)"
    r"|(?:^|/)artifacts/"
    r"|(?:^|/)reports/generated/"
    r"|(?:^|/)\.env(?:\.[^/]*)?$"
    r"|(?:^|/)id_(?:rsa|ed25519)$"
    r"|(?:^|/)known_hosts$"
    r"|\.(?:pem|key|p12|pfx|log)$",
    re.IGNORECASE,
)
SECRET_TEXT_RE = re.compile(
    r"-----BEGIN [A-Z ]*PRIVATE KEY-----"
    r"|\bAKIA[0-9A-Z]{16}\b"
    r"|\b(?:ghp|gho|ghs|ghr)_[A-Za-z0-9]{20,}\b"
    r"|\bxox[baprs]-[A-Za-z0-9-]{10,}\b"
    r"|\b(?:password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S+",
    re.IGNORECASE,
)
ALLOWED_PROVENANCE_FIELDS = {
    "taskId", "stage", "sourceCommit", "reviewVerdict", "securityVerdict", "evidencePaths", "emitter",
}

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


def _assert_no_secret_material(text: str, *, field: str) -> None:
    """Reject values that look like secret material before they can be persisted as memory."""
    if SECRET_TEXT_RE.search(text):
        raise MemoryError(f"{field} contains secret-looking material")


def _assert_safe_memory_path(value: str, *, field: str) -> str:
    """Return a repository-relative memory path, refusing transient and secret-bearing locations.

    Memory must never become a copy of raw logs, key material, or local secret files, so absolute
    paths, home-relative paths, ``..`` traversal, transient output locations, and secret-looking paths
    or values all fail closed instead of being stored.
    """
    path = value.strip()
    if not path:
        raise MemoryError(f"{field} must not contain empty values")
    if "\\" in path:
        raise MemoryError(f"{field} must use repository-relative forward-slash paths")
    while path.startswith("./"):
        path = path[2:]
    if UNSAFE_PATH_RE.search(path):
        raise MemoryError(f"{field} must not reference a transient, secret, or non-relative path")
    if SECRET_TEXT_RE.search(path):
        raise MemoryError(f"{field} contains secret-looking material")
    return path


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


def validate_record(
    raw: object,
    *,
    expected_scope: str | None = None,
    require_provenance: bool = False,
    allow_candidate_status: bool = False,
) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise MemoryError("memory record must be an object")
    allowed = {
        "id", "scope", "type", "component", "task", "summary", "tags",
        "status", "sources", "createdFrom", "supersedes", "provenance",
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
    # The candidate status is reserved for the staging file: retrieval-visible memory may only use the
    # promoted status vocabulary, and only the candidate validator may admit a candidate status.
    permitted_status = set(ALLOWED_STATUS)
    if allow_candidate_status:
        permitted_status.add(CANDIDATE_STATUS)
    if status not in permitted_status:
        if status == CANDIDATE_STATUS:
            raise MemoryError("candidate records are staged in candidates.jsonl and must be promoted first")
        raise MemoryError("status must be active, deprecated, or historical")

    _assert_no_secret_material(summary, field="summary")

    tags = _normalize_tags(raw.get("tags"))
    for tag in tags:
        _assert_no_secret_material(tag, field="tag")

    sources_raw = raw.get("sources", raw.get("createdFrom", []))
    if sources_raw is None:
        sources_raw = []
    if not isinstance(sources_raw, list) or not all(isinstance(item, str) for item in sources_raw):
        raise MemoryError("sources must be an array of strings")
    sources = [
        _assert_safe_memory_path(item, field="sources")
        for item in sources_raw
        if item.strip()
    ]
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

    provenance_raw = raw.get("provenance")
    if provenance_raw is None:
        if require_provenance:
            raise MemoryError("provenance is required to stage or promote project memory")
        provenance = None
    else:
        provenance = validate_provenance(provenance_raw, task=task)

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
        "provenance": provenance,
    }


def validate_provenance(raw: object, *, task: str) -> dict[str, Any]:
    """Validate the release provenance that admits a project-memory candidate or promotion.

    Provenance is what keeps project memory auditable: it names the completed task, the release stage,
    the reviewed source commit, the review and security verdicts that approved the work, the approved
    evidence paths the lesson was derived from, and the reviewed emitter that staged it. A task may
    only emit memory after full approval, so every other shape fails closed and is never written.
    """
    if not isinstance(raw, dict):
        raise MemoryError("provenance must be an object")
    unknown = set(raw) - ALLOWED_PROVENANCE_FIELDS
    if unknown:
        raise MemoryError("provenance has unsupported fields")

    task_id = _bounded_text(raw.get("taskId"), field="provenance.taskId", maximum=64, allow_empty=False)
    if not TASK_ID_RE.fullmatch(task_id):
        raise MemoryError("provenance.taskId has invalid format")
    if not task:
        raise MemoryError("a memory record with provenance must declare its task")
    if task != task_id:
        raise MemoryError("provenance.taskId must match the record task")

    stage = _bounded_text(raw.get("stage"), field="provenance.stage", maximum=32, allow_empty=False).lower()
    if stage != PROMOTION_STAGE:
        raise MemoryError(f"provenance.stage must be {PROMOTION_STAGE}")

    source_commit = _bounded_text(
        raw.get("sourceCommit"), field="provenance.sourceCommit", maximum=64, allow_empty=False
    ).lower()
    if not COMMIT_RE.fullmatch(source_commit):
        raise MemoryError("provenance.sourceCommit must be a lowercase hex commit sha")

    review_verdict = _bounded_text(
        raw.get("reviewVerdict"), field="provenance.reviewVerdict", maximum=32, allow_empty=False
    ).lower()
    if review_verdict != REQUIRED_REVIEW_VERDICT:
        raise MemoryError(f"provenance.reviewVerdict must be {REQUIRED_REVIEW_VERDICT}")
    security_verdict = _bounded_text(
        raw.get("securityVerdict"), field="provenance.securityVerdict", maximum=32, allow_empty=False
    ).lower()
    if security_verdict != REQUIRED_SECURITY_VERDICT:
        raise MemoryError(f"provenance.securityVerdict must be {REQUIRED_SECURITY_VERDICT}")

    emitter = _bounded_text(
        raw.get("emitter"), field="provenance.emitter", maximum=64, allow_empty=False
    ).lower()
    if emitter not in ALLOWED_EMITTERS:
        raise MemoryError("provenance.emitter must be a reviewed memory emitter")

    evidence_raw = raw.get("evidencePaths")
    if evidence_raw is None or not isinstance(evidence_raw, list) or not all(
        isinstance(item, str) for item in evidence_raw
    ):
        raise MemoryError("provenance.evidencePaths must be an array of strings")
    evidence_paths = sorted({
        _assert_safe_memory_path(item, field="provenance.evidencePaths")
        for item in evidence_raw
        if item.strip()
    })
    if not evidence_paths:
        raise MemoryError("provenance.evidencePaths must not be empty")
    if len(evidence_paths) > MAX_CANDIDATE_EVIDENCE_PATHS:
        raise MemoryError("provenance.evidencePaths exceeds maximum item count")
    if any(not path.startswith(APPROVED_EVIDENCE_PREFIXES) for path in evidence_paths):
        raise MemoryError("provenance.evidencePaths must reference approved review, security, or task evidence")

    return {
        "taskId": task_id,
        "stage": stage,
        "sourceCommit": source_commit,
        "reviewVerdict": review_verdict,
        "securityVerdict": security_verdict,
        "emitter": emitter,
        "evidencePaths": evidence_paths,
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


def validate_candidate(raw: object) -> dict[str, Any]:
    """Validate one staged project-memory candidate emitted from approved release evidence.

    A candidate must be project-scoped, declare its task, reference approved evidence paths as its
    sources, carry full release provenance, and keep the ``candidate`` status. Staging is not
    promotion: only ``promote_candidate`` makes a candidate retrieval-visible.
    """
    if not isinstance(raw, dict):
        raise MemoryError("memory candidate must be an object")
    status = _bounded_text(
        raw.get("status", CANDIDATE_STATUS), field="status", maximum=16, allow_empty=False
    ).lower()
    if status != CANDIDATE_STATUS:
        raise MemoryError(f"a staged memory candidate must use status {CANDIDATE_STATUS}")

    record = validate_record(
        {**raw, "scope": raw.get("scope", "project")},
        expected_scope="project",
        require_provenance=True,
        allow_candidate_status=True,
    )
    if not record["sources"]:
        raise MemoryError("a memory candidate must reference approved evidence as sources")
    if any(not source.startswith(APPROVED_EVIDENCE_PREFIXES) for source in record["sources"]):
        raise MemoryError("a memory candidate must reference approved review, security, or task evidence")

    candidate = dict(record)
    candidate["status"] = CANDIDATE_STATUS
    return candidate


def _candidate_path(path: Path | None) -> Path:
    return PROJECT_CANDIDATES if path is None else path


def _promoted_path(path: Path | None) -> Path:
    return PROJECT_MEMORY if path is None else path


def _content_key(record: dict[str, Any]) -> tuple[str, str, str, str]:
    """Deterministic deduplication key: task, component, type, and normalized summary text."""
    normalized_summary = " ".join(re.findall(r"[a-z0-9]+", record["summary"].lower()))
    return (
        record["task"],
        record["component"].lower(),
        record["type"].lower(),
        normalized_summary,
    )


def _append_jsonl(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True, separators=(",", ":")) + "\n")


def _advisory_envelope(key: str, value: object) -> dict[str, Any]:
    """Lifecycle responses stay advisory: they never carry or imply task state."""
    return {
        "memoryVersion": MEMORY_VERSION,
        "authoritativeTaskSource": "tasks/tracker.json",
        "advisoryOnly": True,
        key: value,
    }


def load_candidates(path: Path | None = None) -> list[dict[str, Any]]:
    """Load staged candidates from the append-only candidate file, failing closed on any bad row."""
    target = _candidate_path(path)
    if not target.is_file():
        return []
    candidates: list[dict[str, Any]] = []
    seen: set[str] = set()
    for line_number, line in enumerate(target.read_text(encoding="utf-8").splitlines(), start=1):
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            candidate = validate_candidate(json.loads(line))
        except (json.JSONDecodeError, MemoryError) as exc:
            raise MemoryError(f"invalid memory candidate at {target.name}:{line_number}") from exc
        if candidate["id"] in seen:
            raise MemoryError(f"duplicate memory candidate id in {target.name}")
        seen.add(candidate["id"])
        candidates.append(candidate)
    return candidates


def append_candidate(record: object, *, path: Path | None = None) -> dict[str, Any]:
    """Stage one bounded project-memory candidate emitted from approved release evidence."""
    target = _candidate_path(path)
    candidate = validate_candidate(record)
    existing = load_candidates(target)
    promoted = load_jsonl(_promoted_path(None), expected_scope="project")

    if any(item["id"] == candidate["id"] for item in existing):
        raise MemoryError("memory candidate id already exists")
    if any(item["id"] == candidate["id"] for item in promoted):
        raise MemoryError("memory candidate is already promoted")

    key = _content_key(candidate)
    if any(_content_key(item) == key for item in existing):
        raise MemoryError("duplicate memory candidate content")
    if any(_content_key(item) == key for item in promoted):
        raise MemoryError("duplicate project-memory content")

    task_total = sum(1 for item in existing + promoted if item["task"] == candidate["task"])
    if task_total >= MAX_CANDIDATES_PER_TASK:
        raise MemoryError("task emitted too many project-memory candidates")

    _append_jsonl(target, candidate)
    return _advisory_envelope("candidate", candidate)


def list_candidates(*, path: Path | None = None) -> dict[str, Any]:
    """Report staged candidates and whether each is already promoted. Candidates are not memory."""
    candidates = load_candidates(path)
    promoted_ids = {item["id"] for item in load_jsonl(_promoted_path(None), expected_scope="project")}
    staged = [
        {
            "id": item["id"],
            "task": item["task"],
            "promoted": item["id"] in promoted_ids,
        }
        for item in candidates
    ]
    return _advisory_envelope("candidates", staged)


def promote_candidate(
    candidate_id: object,
    *,
    path: Path | None = None,
    project_path: Path | None = None,
) -> dict[str, Any]:
    """Promote one staged candidate into retrieval-visible project memory.

    Promotion re-validates the staged candidate, refuses a duplicate id or duplicate normalized
    content, keeps the promoted record advisory-only, and never writes task state: ``tasks/tracker.json``
    and ``taskctl`` remain the only authoritative delivery state.
    """
    identifier = _bounded_text(candidate_id, field="candidateId", maximum=128, allow_empty=False)
    if not ID_RE.fullmatch(identifier):
        raise MemoryError("candidateId has invalid format")

    candidate = next((item for item in load_candidates(path) if item["id"] == identifier), None)
    if candidate is None:
        raise MemoryError("unknown memory candidate id")

    promoted_path = _promoted_path(project_path)
    promoted = load_jsonl(promoted_path, expected_scope="project")
    if any(item["id"] == identifier for item in promoted):
        raise MemoryError("memory candidate is already promoted")
    key = _content_key(candidate)
    if any(_content_key(item) == key for item in promoted):
        raise MemoryError("duplicate project-memory content")

    if candidate["supersedes"]:
        # Fail at promotion time rather than persisting a dangling edge that later fails retrieval closed.
        known = {item["id"] for item in load_jsonl(FRAMEWORK_MEMORY, expected_scope="framework")}
        known.update(item["id"] for item in promoted)
        unknown = sorted(set(candidate["supersedes"]) - known)
        if unknown:
            raise MemoryError("supersedes references unknown memory id")

    record = {**candidate, "status": "active"}
    _append_jsonl(promoted_path, record)
    return _advisory_envelope("promoted", record)


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
    # PROJECT_CANDIDATES is deliberately absent here: a staged candidate is not retrieval context and
    # only becomes visible after promote_candidate() writes it into PROJECT_MEMORY.
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


def append_project_record(record: object, *, require_provenance: bool = False) -> dict[str, Any]:
    """Append one reviewed project-memory record directly to retrieval-visible memory.

    The lifecycle-preferred path is ``append_candidate`` followed by ``promote_candidate``, which
    always requires provenance. This direct append stays available for reviewed maintenance writes;
    the permissive default keeps pre-P-WF-T14 records loadable, while the CLI requires provenance for
    every new write.
    """
    normalized = validate_record(
        record,
        expected_scope="project",
        require_provenance=require_provenance,
    )
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

    _append_jsonl(PROJECT_MEMORY, normalized)
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

    candidate_parser = sub.add_parser(
        "add-candidate", help="stage one project-memory candidate emitted from approved evidence"
    )
    candidate_parser.add_argument("json_file")

    sub.add_parser("list-candidates", help="list staged candidates and their promotion state")

    promote_parser = sub.add_parser("promote", help="promote one staged candidate into project memory")
    promote_parser.add_argument("candidate_id")

    args = parser.parse_args(argv)
    try:
        if args.command == "get":
            value = get_relevant_memory(
                query=args.query,
                task_id=args.task_id,
                component=args.component,
                max_items=args.max_items,
            )
        elif args.command == "add-project":
            raw = json.loads(Path(args.json_file).read_text(encoding="utf-8"))
            value = append_project_record(raw, require_provenance=True)
        elif args.command == "add-candidate":
            raw = json.loads(Path(args.json_file).read_text(encoding="utf-8"))
            value = append_candidate(raw)
        elif args.command == "list-candidates":
            value = list_candidates()
        else:
            value = promote_candidate(args.candidate_id)
    except (MemoryError, json.JSONDecodeError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(value, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
