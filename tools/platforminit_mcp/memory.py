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
- A summary is a distilled single line of prose. Multi-line payloads, control/ANSI sequences, shell
  transcripts, log-level lines, timestamped log lines, tracebacks, diff excerpts, and references to
  local transient paths such as ``/tmp/**`` or ``*.log`` files are rejected as raw run output.
- Retrieval is provenance-gated for project memory. Framework memory is reviewed repository source,
  whereas a project row is retrieval context only when it carries validated provenance. A pre-lifecycle
  row without provenance is quarantined and not served (``LEGACY_PROVENANCE_POLICY``) unless every source
  it cites already lies inside the reviewed evidence locations, which is the explicit, bounded
  compatibility window for hand-authored history. ``report_quarantine`` names the excluded rows, so this
  limitation stays observable instead of being claimed away.
- Writes are bound, not merely asserted. Candidate staging and promotion resolve the authoritative
  controller record under ``tasks/tracker.json`` (task present, status at or past ``ready_to_close``,
  recorded ``approve`` and ``clear`` verdicts, and the controller-recorded review/security report paths
  among the cited evidence), verify that the cited commit and evidence paths exist in this repository,
  and require the writing actor to match the reviewed emitter claim. Memory only reads controller state.
- Accepted residuals, stated rather than assumed: the repository-local CLI cannot authenticate a
  process, so the emitter gate is an attributed-actor check inside a reviewed source change; and no
  controller field records the reviewed revision, so the binding proves the cited commit exists and
  contains the cited evidence without proving it is the revision a reviewer approved.
- Unsafe-path filtering is a lexical denylist kept as defense-in-depth. It is backed by the
  existence-at-commit binding above and is not claimed to be a complete path-safety proof.
- Retrieval loads framework memory plus promoted project records only. The candidate file is never
  read by ``get_relevant_memory``, so an unpromoted candidate cannot be returned, not even at the hard
  cap.
- Memory, including promoted memory, stays advisory context. ``tasks/tracker.json`` and ``taskctl``
  remain the only authoritative delivery state, and this lifecycle grants no new authority over it.
- The candidate schema and the promotion gate are the seam a later evidence-distillation feature may
  reuse; distillation may stage candidates but must still pass the same provenance, binding, and
  promotion rules.
"""
from __future__ import annotations

import argparse
import heapq
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
from typing import Any, Sequence

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
# A provenance-carrying (emitted) memory summary is bounded more tightly than the legacy shape bound.
MAX_DISTILLED_SUMMARY_LENGTH = 400

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
# Controller binding: memory reads (and never writes) the authoritative tracker to resolve approval.
CONTROLLER_TASK_STATE = ROOT / "tasks" / "tracker.json"
CONTROLLER_APPROVED_STATUSES = frozenset({"ready_to_close", "done"})
# Compatibility policy for pre-P-WF-T14 project rows: quarantined from retrieval, still loadable.
LEGACY_PROVENANCE_POLICY = "quarantine-provenance-less-project-records"
# Distilled-record input contract: a summary must never be a raw run payload.
CONTROL_CHAR_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
RAW_PAYLOAD_RE = re.compile(
    r"^\s*[$#>]\s"
    r"|Traceback \(most recent call last\)"
    r"|^\s*(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|CRITICAL|NOTICE)\s*[:\-]\s"
    r"|\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}[^,;]{0,32}?\b(?:TRACE|DEBUG|INFO|WARN|WARNING|ERROR|FATAL|CRITICAL)\b"
    r"|(?i:\b(?:stdout|stderr|exit code|exit status)\b\s*[:=])"
    r"|^\s*(?:\+\+\+|---)\s+\S+/"
    r"|(?:^|\s)/(?:tmp|var/log|var/tmp|home|mnt|dev/fd)/"
    r"|\S+\.log\b",
)
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
    r"|(?:^|/)\.git(?:/|$)"
    r"|(?:^|/)\.ssh(?:/|$)"
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


def _assert_distilled_summary(text: str, *, field: str) -> None:
    """Reject raw transient run output; a memory summary must be one distilled line of prose.

    Memory must never become a copy of terminal output, so a summary has to be a single bounded line:
    multi-line payloads, control/ANSI escape sequences, shell transcripts, log-level lines, timestamped
    log lines, tracebacks, diff excerpts, and references to local transient paths such as ``/tmp/**``
    or ``*.log`` files all fail closed.
    """
    if len(text.splitlines()) != 1:
        raise MemoryError(f"{field} must be a single distilled line")
    if CONTROL_CHAR_RE.search(text):
        raise MemoryError(f"{field} must not contain control or ANSI escape sequences")
    if RAW_PAYLOAD_RE.search(text):
        raise MemoryError(f"{field} must be distilled from approved evidence, not raw run output")


def _assert_safe_memory_path(value: str, *, field: str) -> str:
    """Return a repository-relative memory path, refusing transient and secret-bearing locations.

    Memory must never become a copy of raw logs, key material, or local secret files, so absolute
    paths, home-relative paths, ``..`` traversal, URL-ish or empty segments, transient output
    locations, and secret-looking paths or values all fail closed instead of being stored. The check is
    a lexical denylist kept as defense-in-depth: caller identity is bound separately by
    ``assert_emission_bindings``, which requires each cited path to exist at the cited commit.
    """
    path = value.strip()
    if not path:
        raise MemoryError(f"{field} must not contain empty values")
    if "\\" in path:
        raise MemoryError(f"{field} must use repository-relative forward-slash paths")
    while path.startswith("./"):
        path = path[2:]
    if any(marker in path for marker in ("?", "#", "%", "//", "~")):
        raise MemoryError(f"{field} must be a plain repository-relative path")
    if any(segment in ("", ".", "..") for segment in path.rstrip("/").split("/")):
        raise MemoryError(f"{field} must not contain empty, current, or parent directory segments")
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
    _assert_distilled_summary(summary, field="summary")
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
        # Emitted memory is a distilled lesson, so the provenance-carrying shape is bounded more
        # tightly and can never act as a container for a pasted payload.
        if len(summary) > MAX_DISTILLED_SUMMARY_LENGTH:
            raise MemoryError("summary exceeds the distilled-summary bound for provenanced memory")

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


def load_controller_task(task_id: str, *, task_state_path: Path | None = None) -> dict[str, Any]:
    """Return the authoritative controller record for one task, failing closed when unavailable.

    ``tasks/tracker.json`` is the only authoritative task state. Memory reads it to resolve approval; it
    never writes controller state, and an unreadable or unexpected tracker refuses the write instead of
    falling back to the caller's own claim.
    """
    path = CONTROLLER_TASK_STATE if task_state_path is None else task_state_path
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise MemoryError("controller task state is unavailable; provenance cannot be verified") from exc
    tasks = data.get("tasks") if isinstance(data, dict) else None
    if not isinstance(tasks, list):
        raise MemoryError("controller task state has an unexpected shape")
    for task in tasks:
        if isinstance(task, dict) and task.get("id") == task_id:
            return task
    raise MemoryError("controller task state has no record for provenance.taskId")


def assert_controller_approval(
    task_id: str,
    *,
    evidence_paths: Sequence[str],
    task_state_path: Path | None = None,
) -> dict[str, Any]:
    """Bind one provenance claim to controller-recorded approval and its recorded reports.

    A claimed ``approve``/``clear`` pair is not evidence by itself. The task must exist in the
    authoritative controller state, its recorded status must be at or past ``ready_to_close``, its
    recorded review and security verdicts must be the approving ones, and the controller-recorded
    review/security report paths must be cited as candidate evidence.
    """
    task = load_controller_task(task_id, task_state_path=task_state_path)
    status = str(task.get("status") or "").lower()
    if status not in CONTROLLER_APPROVED_STATUSES:
        raise MemoryError(
            "controller task status does not permit memory emission: "
            f"{status or 'unknown'} is not one of {sorted(CONTROLLER_APPROVED_STATUSES)}"
        )
    workflow = task.get("workflow") if isinstance(task.get("workflow"), dict) else {}
    recorded: dict[str, Any] = {}
    for stage, required in (("review", REQUIRED_REVIEW_VERDICT), ("security", REQUIRED_SECURITY_VERDICT)):
        entry = workflow.get(stage) if isinstance(workflow.get(stage), dict) else {}
        if str(entry.get("verdict") or "").lower() != required:
            raise MemoryError(f"controller record does not hold a {required} {stage} verdict")
        recorded[stage] = entry
    cited = set(evidence_paths)
    expected = sorted({str(entry["report"]) for entry in recorded.values() if entry.get("report")})
    if any(path not in cited for path in expected):
        raise MemoryError(
            "provenance.evidencePaths must cite the controller-recorded review and security reports"
        )
    return {"status": status, "branch": str(task.get("branch") or ""), "controllerEvidence": expected}


def _git_output(command: list[str], *, repository: Path | None = None) -> subprocess.CompletedProcess[str]:
    """Run one read-only git query in this repository; memory never mutates repository state."""
    root = ROOT if repository is None else repository
    return subprocess.run(
        ["git", *command], cwd=str(root), text=True, capture_output=True, check=False
    )


def assert_repository_evidence(
    source_commit: str,
    evidence_paths: Sequence[str],
    *,
    repository: Path | None = None,
) -> None:
    """Verify the cited commit and its evidence paths exist in this repository.

    The commit must resolve to a commit object and every cited evidence path must exist at that commit,
    so a candidate cannot point at an invented commit or at a path the reviewed change never contained.
    It does not prove the commit is the revision a reviewer approved - no controller field records that
    revision - and that residual is documented instead of silently assumed.
    """
    if not COMMIT_RE.fullmatch(source_commit):
        raise MemoryError("provenance.sourceCommit must be a lowercase hex commit sha")
    if not evidence_paths:
        raise MemoryError("provenance.evidencePaths must not be empty")
    resolved = _git_output(
        ["rev-parse", "--verify", "--quiet", f"{source_commit}^{{commit}}"], repository=repository
    )
    if resolved.returncode != 0:
        raise MemoryError("provenance.sourceCommit is not a commit in this repository")
    for path in evidence_paths:
        present = _git_output(["cat-file", "-e", f"{source_commit}:{path}"], repository=repository)
        if present.returncode != 0:
            raise MemoryError(f"provenance.evidencePaths is missing at the cited commit: {path}")


def _assert_emitter_actor(emitter: str, actor: object) -> str:
    """Bind the emitter claim to the attributed reviewed actor that performs the write.

    The repository-local CLI cannot authenticate a process, so this is an attributed-actor gate inside a
    reviewed source change rather than an authentication boundary (documented residual).
    """
    actor_name = _bounded_text(actor, field="actor", maximum=64, allow_empty=False).lower()
    if actor_name not in ALLOWED_EMITTERS:
        raise MemoryError("actor must be a reviewed memory emitter")
    if actor_name != emitter:
        raise MemoryError("actor must match provenance.emitter")
    return actor_name


def assert_emission_bindings(
    record: dict[str, Any],
    *,
    actor: object,
    task_state_path: Path | None = None,
    repository: Path | None = None,
    verify_repository: bool = True,
) -> dict[str, Any]:
    """Bind one provenance-carrying record to actor, controller approval, and repository evidence."""
    provenance = record.get("provenance")
    if provenance is None:
        raise MemoryError("emission binding requires provenance")
    _assert_emitter_actor(provenance["emitter"], actor)
    controller = assert_controller_approval(
        provenance["taskId"],
        evidence_paths=provenance["evidencePaths"],
        task_state_path=task_state_path,
    )
    if verify_repository:
        assert_repository_evidence(
            provenance["sourceCommit"], provenance["evidencePaths"], repository=repository
        )
    return controller


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


def append_candidate(
    record: object,
    *,
    actor: object,
    path: Path | None = None,
    task_state_path: Path | None = None,
    repository: Path | None = None,
    verify_repository: bool = True,
) -> dict[str, Any]:
    """Stage one bounded project-memory candidate emitted from approved release evidence.

    Staging is bound rather than merely asserted: the writing actor must match the reviewed emitter
    claim, the task must resolve in authoritative controller state with recorded approval, and the cited
    commit plus evidence paths must exist in this repository.
    """
    target = _candidate_path(path)
    candidate = validate_candidate(record)
    assert_emission_bindings(
        candidate,
        actor=actor,
        task_state_path=task_state_path,
        repository=repository,
        verify_repository=verify_repository,
    )
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
    actor: object,
    path: Path | None = None,
    project_path: Path | None = None,
    task_state_path: Path | None = None,
    repository: Path | None = None,
    verify_repository: bool = True,
) -> dict[str, Any]:
    """Promote one staged candidate into retrieval-visible project memory.

    Promotion re-validates the staged candidate, re-resolves the actor, controller, and repository
    bindings at promotion time, refuses a duplicate id or duplicate normalized content, keeps the
    promoted record advisory-only, and never writes task state: ``tasks/tracker.json`` and ``taskctl``
    remain the only authoritative delivery state.
    """
    identifier = _bounded_text(candidate_id, field="candidateId", maximum=128, allow_empty=False)
    if not ID_RE.fullmatch(identifier):
        raise MemoryError("candidateId has invalid format")

    candidate = next((item for item in load_candidates(path) if item["id"] == identifier), None)
    if candidate is None:
        raise MemoryError("unknown memory candidate id")
    assert_emission_bindings(
        candidate,
        actor=actor,
        task_state_path=task_state_path,
        repository=repository,
        verify_repository=verify_repository,
    )

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


def is_retrieval_eligible(record: dict[str, Any]) -> bool:
    """Report whether one loaded record may be returned as retrieval context.

    Project memory is provenance-gated: a project row carrying validated provenance is eligible.
    Framework memory ships as reviewed repository source rather than as emitted task evidence, so it
    stays eligible without provenance. A project row without provenance is quarantined
    (``LEGACY_PROVENANCE_POLICY``) unless every source it cites already lies inside the approved
    evidence locations, which admits hand-authored pre-lifecycle history only while its own citations
    stay inside the reviewed evidence boundary.
    """
    if record["scope"] != "project":
        return True
    if record.get("provenance") is not None:
        return True
    sources = record.get("sources") or []
    return bool(sources) and all(
        source.startswith(APPROVED_EVIDENCE_PREFIXES) for source in sources
    )


def quarantined_project_records(*, project_path: Path | None = None) -> list[dict[str, Any]]:
    """Return the project records excluded from retrieval by the provenance compatibility policy."""
    records = load_jsonl(_promoted_path(project_path), expected_scope="project")
    return [record for record in records if not is_retrieval_eligible(record)]


def report_quarantine(*, project_path: Path | None = None) -> dict[str, Any]:
    """Report the quarantined project rows, so the compatibility limitation stays observable."""
    quarantined = quarantined_project_records(project_path=project_path)
    return _advisory_envelope(
        "quarantine",
        {
            "policy": LEGACY_PROVENANCE_POLICY,
            "retrievalVisible": False,
            "count": len(quarantined),
            "ids": [record["id"] for record in quarantined],
        },
    )


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
    # tie-break, or baseline path can return a superseded fact, and so a supersession edge naming a
    # quarantined row is still resolved instead of failing closed as dangling.
    suppressed_ids = superseded_record_ids(all_records)
    # Provenance-gated retrieval: a project row without provenance is quarantined compatibly rather than
    # served, so retrieval-visible project memory is exactly the promoted, provenance-carrying set.
    eligible = [record for record in all_records if is_retrieval_eligible(record)]

    query_tokens = _tokens(" ".join([query_text, task_text, component_text]))
    ranked: list[tuple[int, int, dict[str, Any]]] = []
    for record in eligible:
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


def append_project_record(
    record: object,
    *,
    require_provenance: bool = False,
    actor: object | None = None,
    task_state_path: Path | None = None,
    repository: Path | None = None,
    verify_repository: bool = True,
) -> dict[str, Any]:
    """Append one reviewed project-memory record directly to retrieval-visible memory.

    The lifecycle-preferred path is ``append_candidate`` followed by ``promote_candidate``. This direct
    append stays available for reviewed maintenance writes; ``require_provenance=False`` keeps the
    hand-authored compatibility path working, while the CLI always passes ``require_provenance=True`` so
    an emitted record is controller-, evidence-, and actor-bound before it becomes retrieval context.
    """
    normalized = validate_record(
        record,
        expected_scope="project",
        require_provenance=require_provenance,
    )
    if normalized["provenance"] is not None:
        assert_emission_bindings(
            normalized,
            actor=actor,
            task_state_path=task_state_path,
            repository=repository,
            verify_repository=verify_repository,
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


def contract_self_checks(
    *,
    repository: Path | None = None,
    task_state_path: Path | None = None,
) -> dict[str, Any]:
    """Replay the memory contract against throwaway fixtures as focused regression evidence.

    The module's unittest harness is a file outside this task's bounded allowed scope, so the focused
    regression gate for the P-WF-T14 review batch ships here instead: the quarantine policy (F1), the
    controller/commit/actor binding (F2), the distilled-record input contract (F3), and the path-safety
    denylist (F4) are re-verified by this command, which keeps them executable release evidence rather
    than prose. Every fixture is temporary and the shipped memory files are only read, never written.
    """
    checks: list[tuple[str, bool]] = []
    notes: list[str] = []
    task_id = "P-WF-T14"
    review_report = "docs/reviews/P-WF-T14.md"
    security_report = "docs/security-reviews/P-WF-T14.md"
    evidence = (review_report, security_report)
    emitter = ALLOWED_EMITTERS[0]

    def record_check(name: str, outcome: bool) -> None:
        checks.append((name, bool(outcome)))

    def refused(call, *args, **kwargs) -> bool:
        try:
            call(*args, **kwargs)
        except MemoryError:
            return True
        return False

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        project = root / "records.jsonl"
        framework = root / "framework.jsonl"
        candidates = root / "candidates.jsonl"
        tracker = task_state_path if task_state_path is not None else root / "tracker.json"

        def write_tracker(status: str, review: str = "approve", security: str = "clear") -> None:
            tracker.write_text(
                json.dumps(
                    {
                        "schemaVersion": 1,
                        "tasks": [
                            {
                                "id": task_id,
                                "status": status,
                                "branch": "feat/self-check",
                                "workflow": {
                                    "review": {"verdict": review, "report": review_report},
                                    "security": {"verdict": security, "report": security_report},
                                },
                            }
                        ],
                    }
                ),
                encoding="utf-8",
            )

        def candidate(
            record_id: str,
            *,
            summary: str = "A distilled release lesson about evidence reuse.",
            cited: tuple[str, ...] = evidence,
        ) -> dict[str, Any]:
            return {
                "id": record_id,
                "scope": "project",
                "type": "lesson",
                "component": "release",
                "task": task_id,
                "summary": summary,
                "tags": ["release"],
                "status": CANDIDATE_STATUS,
                "sources": list(cited),
                "provenance": {
                    "taskId": task_id,
                    "stage": PROMOTION_STAGE,
                    "sourceCommit": "abcdef1",
                    "reviewVerdict": REQUIRED_REVIEW_VERDICT,
                    "securityVerdict": REQUIRED_SECURITY_VERDICT,
                    "emitter": emitter,
                    "evidencePaths": list(cited),
                },
            }

        # F1 - provenance-gated retrieval and the compatibility policy for hand-authored history.
        legacy = {
            "id": "project.self.legacy",
            "scope": "project",
            "type": "lesson",
            "component": "memory",
            "task": "",
            "summary": "Hand-authored legacy lesson about release evidence handling.",
            "tags": [],
            "status": "active",
            "sources": [".roomodes"],
        }
        emitted = {
            **candidate("project.self.emitted", summary="Emitted lesson about release evidence handling."),
            "status": "active",
        }
        project.write_text(
            json.dumps(legacy, separators=(",", ":")) + "\n" + json.dumps(emitted, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        framework.write_text("", encoding="utf-8")
        record_check(
            "F1 provenance-less row citing outside the reviewed evidence locations is quarantined",
            [item["id"] for item in quarantined_project_records(project_path=project)]
            == ["project.self.legacy"],
        )

        global PROJECT_MEMORY, FRAMEWORK_MEMORY
        saved_paths = (PROJECT_MEMORY, FRAMEWORK_MEMORY)
        try:
            PROJECT_MEMORY, FRAMEWORK_MEMORY = project, framework
            retrieval = get_relevant_memory(query="release evidence handling", max_items=HARD_MAX_ITEMS)
        finally:
            PROJECT_MEMORY, FRAMEWORK_MEMORY = saved_paths
        record_check(
            "F1 retrieval returns the provenance-carrying row only",
            [item["id"] for item in retrieval["items"]] == ["project.self.emitted"],
        )
        record_check(
            "F1 retrieval response keys are unchanged",
            set(retrieval)
            == {"memoryVersion", "authoritativeTaskSource", "advisoryOnly", "itemCount", "items"},
        )

        # F2 - controller, evidence, and attributed-actor binding.
        write_tracker("in_progress")
        record_check(
            "F2 staging refuses a controller status that is not an approved completed state",
            refused(
                append_candidate,
                candidate("project.self.refused"),
                actor=emitter,
                path=candidates,
                task_state_path=tracker,
                verify_repository=False,
            ),
        )
        write_tracker("ready_to_close", review="request_changes")
        record_check(
            "F2 staging refuses a non-approving controller review verdict",
            refused(
                append_candidate,
                candidate("project.self.refused"),
                actor=emitter,
                path=candidates,
                task_state_path=tracker,
                verify_repository=False,
            ),
        )
        write_tracker("ready_to_close")
        record_check(
            "F2 staging refuses evidence that omits the controller-recorded reports",
            refused(
                append_candidate,
                candidate("project.self.refused", cited=(review_report,)),
                actor=emitter,
                path=candidates,
                task_state_path=tracker,
                verify_repository=False,
            ),
        )
        record_check(
            "F2 staging refuses an actor that does not match the reviewed emitter claim",
            refused(
                append_candidate,
                candidate("project.self.refused"),
                actor=ALLOWED_EMITTERS[1],
                path=candidates,
                task_state_path=tracker,
                verify_repository=False,
            ),
        )
        record_check(
            "F2 staging refuses an unreadable controller record",
            refused(
                append_candidate,
                candidate("project.self.refused"),
                actor=emitter,
                path=candidates,
                task_state_path=root / "absent-tracker.json",
                verify_repository=False,
            ),
        )

        staged = append_candidate(
            candidate("project.self.staged"),
            actor=emitter,
            path=candidates,
            task_state_path=tracker,
            verify_repository=False,
        )
        record_check(
            "F2 staging accepts an approved completed task and stays advisory",
            staged["candidate"]["id"] == "project.self.staged"
            and staged["advisoryOnly"]
            and staged["authoritativeTaskSource"] == "tasks/tracker.json",
        )
        record_check(
            "F2 promotion re-binds the emitter actor",
            refused(
                promote_candidate,
                "project.self.staged",
                actor=ALLOWED_EMITTERS[1],
                path=candidates,
                project_path=project,
                task_state_path=tracker,
                verify_repository=False,
            ),
        )
        promoted = promote_candidate(
            "project.self.staged",
            actor=emitter,
            path=candidates,
            project_path=project,
            task_state_path=tracker,
            verify_repository=False,
        )
        record_check(
            "F2 promotion keeps promoted memory advisory and claims no task authority",
            promoted["promoted"]["status"] == "active" and promoted["advisoryOnly"],
        )

        head = _git_output(["rev-parse", "HEAD"], repository=repository)
        if head.returncode == 0 and head.stdout.strip():
            commit = head.stdout.strip()
            record_check(
                "F2 commit binding refuses an unresolvable commit",
                refused(
                    assert_repository_evidence,
                    "0" * 40,
                    ["tasks/tracker.json"],
                    repository=repository,
                ),
            )
            record_check(
                "F2 commit binding accepts evidence committed at the cited revision",
                not refused(
                    assert_repository_evidence, commit, ["tasks/tracker.json"], repository=repository
                ),
            )
            record_check(
                "F2 commit binding refuses evidence absent from the cited revision",
                refused(
                    assert_repository_evidence,
                    commit,
                    ["docs/reviews/P-WF-T14-absent.md"],
                    repository=repository,
                ),
            )
        else:
            notes.append("F2 repository binding checks skipped: git metadata unavailable")

        # F3 - distilled-record input contract.
        raw_summaries = (
            "$ make deploy\nERROR: deploy failed\n",
            "Traceback (most recent call last): ConnectionError",
            "2026-09-23T19:34:36Z ERROR k3s deploy failed",
            "ERROR: retry budget exhausted",
            "Full transcript stored at /tmp/platforminit-evidence/run.log",
            "see the captured output in build-output.log",
            "\x1b[31mFAILED\x1b[0m validation suite",
        )
        record_check(
            "F3 raw run payloads are refused as summaries",
            all(
                refused(
                    validate_record,
                    {**candidate("project.self.raw"), "summary": summary},
                    expected_scope="project",
                    require_provenance=True,
                    allow_candidate_status=True,
                )
                for summary in raw_summaries
            ),
        )
        distilled_summary = (
            "Reuse passing focused validator evidence only while the controller-recorded fingerprint "
            "still matches the changed scope."
        )
        record_check(
            "F3 distilled prose summaries are accepted",
            validate_record(
                {**candidate("project.self.distilled"), "summary": distilled_summary},
                expected_scope="project",
                require_provenance=True,
                allow_candidate_status=True,
            )["summary"]
            == distilled_summary,
        )
        long_summary = " ".join(["Distilled"] * 60)
        record_check(
            "F3 provenance-carrying summaries respect the distilled bound",
            refused(
                validate_record,
                {**candidate("project.self.long"), "summary": long_summary},
                expected_scope="project",
                require_provenance=True,
                allow_candidate_status=True,
            )
            and len(long_summary) < MAX_SUMMARY_LENGTH,
        )

        # F4 - path-safety denylist, kept as defense-in-depth behind the binding above.
        unsafe_paths = (
            "../docs/reviews/P-WF-T14.md",
            "/tmp/platforminit-evidence/run.log",
            "docs//reviews/P-WF-T14.md",
            "docs/reviews/P-WF-T14.md?ref=dev",
            "docs/reviews/P-WF-T14.md#section",
            ".git/config",
            ".ssh/id_rsa",
            "docs/reviews/P-WF-T14.LOG",
        )
        record_check(
            "F4 unsafe or ambiguous source paths are refused",
            all(
                refused(
                    validate_record,
                    {
                        "id": "project.self.path",
                        "scope": "project",
                        "summary": "Distilled lesson under path review.",
                        "sources": [path],
                    },
                    expected_scope="project",
                )
                for path in unsafe_paths
            ),
        )
        record_check(
            "F4 ordinary reviewed source paths are still accepted",
            validate_record(
                {
                    "id": "project.self.path",
                    "scope": "project",
                    "summary": "Distilled lesson under path review.",
                    "sources": [review_report],
                },
                expected_scope="project",
            )["sources"]
            == [review_report],
        )

    failed = [name for name, outcome in checks if not outcome]
    return _advisory_envelope(
        "contractCheck",
        {
            "ok": not failed,
            "checkCount": len(checks),
            "passedCount": len(checks) - len(failed),
            "failedChecks": failed,
            "checks": [{"name": name, "passed": outcome} for name, outcome in checks],
            "notes": notes,
        },
    )


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
    add_parser.add_argument("--actor", required=True, choices=sorted(ALLOWED_EMITTERS))

    candidate_parser = sub.add_parser(
        "add-candidate", help="stage one project-memory candidate emitted from approved evidence"
    )
    candidate_parser.add_argument("json_file")
    candidate_parser.add_argument("--actor", required=True, choices=sorted(ALLOWED_EMITTERS))

    sub.add_parser("list-candidates", help="list staged candidates and their promotion state")

    sub.add_parser("quarantine-report", help="report project records quarantined from retrieval")

    sub.add_parser("contract-check", help="replay the project-memory contract against temp fixtures")

    promote_parser = sub.add_parser("promote", help="promote one staged candidate into project memory")
    promote_parser.add_argument("candidate_id")
    promote_parser.add_argument("--actor", required=True, choices=sorted(ALLOWED_EMITTERS))

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
            value = append_project_record(raw, actor=args.actor)
        elif args.command == "add-candidate":
            raw = json.loads(Path(args.json_file).read_text(encoding="utf-8"))
            value = append_candidate(raw, actor=args.actor)
        elif args.command == "list-candidates":
            value = list_candidates()
        elif args.command == "quarantine-report":
            value = report_quarantine()
        elif args.command == "contract-check":
            value = contract_self_checks()
        else:
            value = promote_candidate(args.candidate_id, actor=args.actor)
    except (MemoryError, json.JSONDecodeError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(value, ensure_ascii=False, indent=2))
    if isinstance(value, dict) and (value.get("contractCheck") or {}).get("ok") is False:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
