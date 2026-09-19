#!/usr/bin/env python3
"""Smoke-test the fresh-child delivery pipeline contract (P-WF-T08).

Three gates, checked offline: read-only, no infrastructure workflow, no task-state write.

Gate 1 - a fresh child is used for every specialist stage: every lifecycle status has its own stage,
         the controller returns the tracker-declared mode for each specialist stage, and each of those
         modes is a declared `platforminit-*` mode that starts as a fresh child. Extended by P-WF-T09:
         each specialist mode is statically terminal at its own controller transition and forbids
         launching the next lifecycle stage, including a `switch_mode` continuation of the lifecycle
         (load-bearing: the check fails when that marker is removed from a specialist mode), the
         shared `.roo/rules/05-lifecycle-routing.md` rule carries the same invariant for every mode,
         and the `next-task` startup gate orders
         `git fetch origin`, a fast-forward-only `dev` refresh, and only then MCP task resolution.
Gate 2 - MCP context is available after every handoff: every specialist mode declares the `mcp`
         group and boots `health` plus `get_delivery_context`, and the compact delivery payload
         re-derives stage, next mode, and transition command from authoritative state. Extended by
         P-WF-T09: the smoke procedure must state that this static layer proves contract text only and
         does not prove Zoo parent/child provenance, and must declare the runtime FAIL for a
         specialist child that itself launches the next lifecycle stage.
Gate 3 - the handoff payload stays bounded and no stale stage is executed: the handoff payload is
         exactly the documented bounded field list, an unknown task id yields a state marker instead
         of a stage, and an unmapped or closed status routes to nothing instead of reusing the
         previous stage.

The gate count stays three: the P-WF-T09 terminal-stage and startup-gate invariants extend gates 1
and 2 so the documented three-gate contract in `.roo/commands/pipeline-smoke.md` remains accurate.

Usage:
  python3 tools/platforminit_mcp/validate_pipeline_smoke.py
"""
from __future__ import annotations

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
MODULES = Path(__file__).resolve().parent
MODES = ROOT / ".roomodes"
TRACKER = ROOT / "tasks" / "tracker.json"
NEXT_TASK_COMMAND = ROOT / ".roo" / "commands" / "next-task.md"
SMOKE_COMMAND = ROOT / ".roo" / "commands" / "pipeline-smoke.md"

PLATFORM_TRACK = "platform"
MODE_PREFIX = "platforminit-"

# Specialist stages of the fresh-child pipeline and the tracker field that names their mode.
MODE_FIELDS = ("implementationMode", "reviewMode", "securityMode", "releaseMode")
STAGE_STATUS = (
    ("in_progress", "implementation", "implementationMode"),
    ("needs_review", "review", "reviewMode"),
    ("needs_security_review", "security-review", "securityMode"),
    ("ready_to_close", "release", "releaseMode"),
)
NON_ROUTING_STATUSES = ("blocked", "done")
CANONICAL_STATUSES = ("pending",) + tuple(status for status, _stage, _field in STAGE_STATUS) + NON_ROUTING_STATUSES

# Bounded handoff payload (P-WF-T03/P-WF-T01): these seven fields and nothing else.
EXPECTED_HANDOFF_PAYLOAD = (
    "task id",
    "stage",
    "acceptance gaps",
    "changed paths",
    "evidence paths",
    "unresolved risks",
    "controller transition",
)
HANDOFF_MAX_FIELDS = 7
HANDOFF_MAX_FIELD_LENGTH = 40
HANDOFF_SECTION_KEYS = {"payload"}

FRESH_CHILD_MARKERS = ("child start", "fresh child")
SMOKE_CHILD_MARKERS = ("fresh Zoo `new_task` child", "reload", "health", "get_delivery_context")
# Routing must come from authoritative controller status only, never from remembered context.
ROUTING_MARKERS = (
    "Route only from authoritative status",
    "Reload MCP `get_delivery_context`",
    "discard stage conversation context",
    "Never continue implementation",
)
SAMPLE_TASK_ID = "P-WF-T08"
UNKNOWN_TASK_ID = "P-ZZ-T99"
UNMAPPED_STATUS = "archived"

# Terminal specialist contract (P-WF-T09). Each specialist mode runs exactly its own stage, records its
# own controller transition, then terminates; only the orchestrator routes the next stage.
LIFECYCLE_RULE = ROOT / ".roo" / "rules" / "05-lifecycle-routing.md"
LIFECYCLE_RULE_DIR = ROOT / ".roo" / "rules"
SPECIALIST_MODES = (
    "platforminit-deepseek-coder",
    "platforminit-openai-reviewer",
    "platforminit-owasp-reviewer",
    "platforminit-release-manager",
)
ORCHESTRATOR_MODE = "platforminit-orchestrator"
ROUTING_OWNER_MARKER = "the orchestrator is the only next-stage routing owner"
TERMINAL_STAGE_MARKERS = (
    "run exactly this one stage",
    "taskctl",
    "attempt_completion",
    "terminate",
)
# Load-bearing self-routing prohibitions. The `switch_mode` marker is verified by a negative control:
# deleting it from a specialist mode declaration must make `terminal_mode_errors()` report the mode,
# so a mode can never regain lifecycle continuation through `switch_mode` unnoticed.
SELF_ROUTING_PROHIBITION_MARKERS = (
    "never call `new_task`",
    "never spawn a child",
    "never use `switch_mode` to continue the lifecycle",
    "never hand off to the next lifecycle stage",
)
LIFECYCLE_RULE_MARKERS = (
    "run exactly this one stage",
    "attempt_completion",
    "terminate",
    "static proof boundary",
    "does not prove zoo parent/child provenance",
) + SELF_ROUTING_PROHIBITION_MARKERS + (ROUTING_OWNER_MARKER,)
SMOKE_PROOF_BOUNDARY_MARKERS = (
    "contract text only",
    "does not prove zoo parent/child provenance",
    "runtime parent-routing",
)
SMOKE_SELF_ROUTING_FAIL_MARKERS = (
    "specialist child that itself launches the next lifecycle stage",
    "nested `new_task`",
)
STARTUP_GATE_HEADING = "## Startup gate"
STARTUP_GATE_ORDER = ("git fetch origin", "fast-forward-only", "get_delivery_context")
STARTUP_GATE_MARKERS = (
    "git status --short",
    "origin/dev",
    "never `reset --hard`",
    "never discard dirty work automatically",
    "hard stop",
    "in-flight dirty feature branch",
)


def _report(title: str, errors: list[str]) -> None:
    print(title + ":", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)


def _import_context():
    sys.path.insert(0, str(MODULES))
    try:
        import context as mcp_context  # type: ignore[import-not-found]  # path-scoped import
    finally:
        sys.path.pop(0)
    return mcp_context


def _load_modes() -> list[dict]:
    return json.loads(MODES.read_text(encoding="utf-8")).get("customModes", [])


def _platform_tasks() -> list[dict]:
    return [
        task
        for task in json.loads(TRACKER.read_text(encoding="utf-8"))["tasks"]
        if task.get("track") == PLATFORM_TRACK
    ]


def _role_modes(tasks: list[dict]) -> dict[str, set[str]]:
    """Modes declared by authoritative tracker tasks, per specialist stage role."""
    roles: dict[str, set[str]] = {field: set() for field in MODE_FIELDS}
    for task in tasks:
        for field in MODE_FIELDS:
            value = task.get(field)
            if isinstance(value, str) and value:
                roles[field].add(value)
    return roles


def _mode_map(modes: list[dict]) -> dict[str, dict]:
    return {mode.get("slug", ""): mode for mode in modes}


def _role_mode_errors(
    field: str, stage_name: str, roles: dict[str, set[str]], declared: dict[str, dict], smoke: str
) -> list[str]:
    """Each specialist stage must resolve to a declared, documented, fresh-child mode."""
    errors: list[str] = []
    modes = sorted(roles[field])
    if not modes:
        errors.append(
            f"{field}: no platform task declares it, so the {stage_name} stage has no fresh-child mode"
        )
        return errors
    for mode in modes:
        if not mode.startswith(MODE_PREFIX):
            errors.append(f"{field}: {mode!r} is not a PlatformInit mode")
            continue
        record = declared.get(mode)
        if not record:
            errors.append(f"{field}: {mode!r} is not declared in .roomodes")
            continue
        if f"`{mode}`" not in smoke:
            errors.append(f"{stage_name} stage: mode {mode!r} is not documented in {SMOKE_COMMAND.name}")
        if "mcp" not in record.get("groups", []):
            errors.append(f"{mode}: missing mcp group, so a handoff has no delivery context")
        instructions = record.get("customInstructions", "")
        for required in ("health", "get_delivery_context"):
            if required not in instructions:
                errors.append(f"{mode}: instructions do not call MCP {required}")
        if not any(marker in instructions for marker in FRESH_CHILD_MARKERS):
            errors.append(f"{mode}: instructions do not start as a fresh child")
        errors.extend(terminal_mode_errors(mode, record))
    return errors


def _normalize(text: str) -> str:
    """Contract markers are matched case-insensitively with whitespace collapsed, so Markdown line
    wrapping can never silently break a required phrase."""
    return " ".join(text.lower().split())


def terminal_mode_errors(mode: str, record: dict) -> list[str]:
    """A specialist mode must be terminal at its own controller transition and never route onward."""
    errors: list[str] = []
    instructions = _normalize(record.get("customInstructions", ""))
    for marker in TERMINAL_STAGE_MARKERS:
        if marker not in instructions:
            errors.append(f"{mode}: instructions do not declare the stage terminal ({marker!r})")
    for marker in SELF_ROUTING_PROHIBITION_MARKERS:
        if marker not in instructions:
            errors.append(
                f"{mode}: instructions do not forbid launching the next lifecycle stage ({marker!r})"
            )
    if ROUTING_OWNER_MARKER not in instructions:
        errors.append(f"{mode}: instructions do not defer next-stage routing to the orchestrator")
    return errors


def lifecycle_routing_rule_errors(declared: dict[str, dict]) -> list[str]:
    """Every mode must load the shared lifecycle-routing rule, not only the mode registry."""
    errors: list[str] = []
    if LIFECYCLE_RULE.parent != LIFECYCLE_RULE_DIR:
        errors.append(f"{LIFECYCLE_RULE.name}: shared rule must live in .roo/rules/ so every mode loads it")
    if not LIFECYCLE_RULE.is_file():
        errors.append(f"{LIFECYCLE_RULE.name}: shared lifecycle-routing rule is missing")
        return errors
    rule = _normalize(LIFECYCLE_RULE.read_text(encoding="utf-8"))
    for marker in LIFECYCLE_RULE_MARKERS:
        if marker not in rule:
            errors.append(f"{LIFECYCLE_RULE.name}: lost the shared lifecycle-routing invariant {marker!r}")
    for mode in SPECIALIST_MODES:
        if mode not in declared:
            errors.append(f"{mode}: terminal specialist mode is not declared in .roomodes")
        if mode not in rule:
            errors.append(f"{LIFECYCLE_RULE.name}: shared rule does not name the terminal specialist {mode!r}")
    orchestrator = declared.get(ORCHESTRATOR_MODE, {}).get("customInstructions", "")
    if ROUTING_OWNER_MARKER not in _normalize(orchestrator):
        errors.append(
            f"{ORCHESTRATOR_MODE}: instructions do not claim the only next-stage routing ownership"
        )
    return errors


def next_task_startup_gate_errors(contract: str) -> list[str]:
    """The next-task startup gate must fetch and fast-forward `dev` before MCP task resolution."""
    errors: list[str] = []
    normalized = _normalize(contract)
    start = normalized.find(_normalize(STARTUP_GATE_HEADING))
    if start == -1:
        errors.append(
            f"{NEXT_TASK_COMMAND.name}: no ordered startup gate, so a task can resolve from stale local dev"
        )
        return errors
    end = normalized.find(" ## ", start + 1)
    section = normalized[start:] if end == -1 else normalized[start:end]
    positions = [section.find(marker) for marker in STARTUP_GATE_ORDER]
    for marker, index in zip(STARTUP_GATE_ORDER, positions):
        if index == -1:
            errors.append(f"{NEXT_TASK_COMMAND.name}: startup gate does not {marker!r}")
    found = [index for index in positions if index != -1]
    if len(found) == len(positions) and found != sorted(found):
        errors.append(
            f"{NEXT_TASK_COMMAND.name}: startup gate must order git fetch origin, then a "
            "fast-forward-only dev refresh, then MCP task resolution"
        )
    for marker in STARTUP_GATE_MARKERS:
        if marker not in section:
            errors.append(f"{NEXT_TASK_COMMAND.name}: startup gate is missing the safety marker {marker!r}")
    return errors


def smoke_proof_boundary_errors(smoke: str) -> list[str]:
    """The smoke procedure must separate static/contract proof from runtime routing proof."""
    errors: list[str] = []
    normalized = _normalize(smoke)
    for marker in SMOKE_PROOF_BOUNDARY_MARKERS:
        if marker not in normalized:
            errors.append(f"{SMOKE_COMMAND.name}: static/runtime proof boundary is not stated ({marker!r})")
    for marker in SMOKE_SELF_ROUTING_FAIL_MARKERS:
        if marker not in normalized:
            errors.append(
                f"{SMOKE_COMMAND.name}: runtime FAIL for a specialist child that routes the next "
                f"stage is not stated ({marker!r})"
            )
    return errors


def gate1_errors(
    mcp_context, modes: list[dict], roles: dict[str, set[str]], smoke: str
) -> list[str]:
    """Gate 1: every specialist stage is a fresh child in its own controller-selected mode."""
    errors: list[str] = []
    declared = _mode_map(modes)
    mapping = mcp_context.STAGE_BY_STATUS
    for status in CANONICAL_STATUSES:
        if status not in mapping:
            errors.append(f"stage mapping has no entry for lifecycle status {status!r}")
    if len(set(mapping.values())) != len(mapping):
        errors.append("two lifecycle statuses share one stage name, so stages cannot be told apart")

    for status, stage_name, field in STAGE_STATUS:
        if mapping.get(status) != stage_name:
            errors.append(f"{status}: stage is {mapping.get(status)!r}, expected {stage_name!r}")
        candidates = sorted(roles[field])
        if candidates:
            sample_mode = candidates[0]
            routing = mcp_context.transition({"id": SAMPLE_TASK_ID, "status": status, field: sample_mode})
            if routing.get("nextMode") != sample_mode:
                errors.append(
                    f"{stage_name} stage: nextMode is {routing.get('nextMode')!r} instead of the "
                    f"tracker-declared {sample_mode!r}"
                )
            command = routing.get("command") or ""
            if "taskctl.py" not in command or "--actor" not in command:
                errors.append(f"{stage_name} stage: transition does not go through the controller")
        errors.extend(_role_mode_errors(field, stage_name, roles, declared, smoke))

    errors.extend(lifecycle_routing_rule_errors(declared))
    if not NEXT_TASK_COMMAND.is_file():
        errors.append(f"{NEXT_TASK_COMMAND.name}: fresh-child lifecycle contract missing")
    else:
        contract = NEXT_TASK_COMMAND.read_text(encoding="utf-8")
        for marker in ROUTING_MARKERS:
            if marker not in contract:
                errors.append(f"{NEXT_TASK_COMMAND.name}: lost the fresh-child routing marker {marker!r}")
        for status, _stage, field in STAGE_STATUS:
            if f"`{status}` -> {field}" not in contract:
                errors.append(f"{NEXT_TASK_COMMAND.name}: no authoritative route for {status!r}")
        errors.extend(next_task_startup_gate_errors(contract))
    return errors


def gate2_errors(mcp_context, smoke: str, modes: list[dict], roles: dict[str, set[str]]) -> list[str]:
    """Gate 2: MCP delivery context is re-derived for every handoff, for every stage mode."""
    errors: list[str] = []
    declared = _mode_map(modes)
    stage_modes = sorted({mode for field in MODE_FIELDS for mode in roles[field]})
    if stage_modes:
        for mode in stage_modes:
            record = declared.get(mode, {})
            if "mcp" not in record.get("groups", []):
                errors.append(f"{mode}: cannot answer MCP health/get_delivery_context after a handoff")
    for marker in SMOKE_CHILD_MARKERS:
        if marker not in smoke:
            errors.append(f"{SMOKE_COMMAND.name}: child startup is not documented ({marker!r})")
    errors.extend(smoke_proof_boundary_errors(smoke))

    summary = mcp_context.active_task_summary()
    if "id" in summary:
        for field in ("stage", "nextMode", "command"):
            if field not in summary:
                errors.append(f"delivery context does not carry {field!r}, so a handoff cannot re-derive its stage")
        status = summary.get("status")
        if status in mcp_context.STAGE_BY_STATUS and summary.get("stage") != mcp_context.STAGE_BY_STATUS[status]:
            errors.append(
                f"delivery context stage {summary.get('stage')!r} does not match authoritative status {status!r}"
            )
    elif "state" not in summary:
        errors.append("delivery context carries neither a task summary nor a documented state marker")
    return errors


def gate3_errors(mcp_context, smoke: str) -> list[str]:
    """Gate 3: the handoff payload is bounded and no stale stage can be executed."""
    errors: list[str] = []
    payload = list(mcp_context.HANDOFF_PAYLOAD)
    if payload != list(EXPECTED_HANDOFF_PAYLOAD):
        errors.append(
            "handoff payload drifted from the bounded field list: " + ", ".join(repr(item) for item in payload)
        )
    if len(payload) > HANDOFF_MAX_FIELDS:
        errors.append(f"handoff payload carries {len(payload)} fields, above the bound of {HANDOFF_MAX_FIELDS}")
    if len(set(payload)) != len(payload):
        errors.append("handoff payload repeats a field")
    for item in payload:
        if not item or len(item) > HANDOFF_MAX_FIELD_LENGTH:
            errors.append(f"handoff payload field is not bounded: {item!r}")
    for item in EXPECTED_HANDOFF_PAYLOAD:
        if item not in smoke:
            errors.append(f"{SMOKE_COMMAND.name}: bounded handoff field {item!r} is not documented")

    delivery = mcp_context.delivery_context()
    handoff = delivery.get("handoff", {})
    if set(handoff) != HANDOFF_SECTION_KEYS:
        errors.append(
            "handoff section carries fields beyond the bounded payload: " + ", ".join(sorted(handoff))
        )
    if list(handoff.get("payload", [])) != payload:
        errors.append("delivery context does not publish the bounded handoff payload")
    for removed in ("indexing", "suggestedPaths"):
        if removed in delivery:
            errors.append(f"delivery context still carries the removed {removed!r} block")

    stale = mcp_context.active_task_summary(task_id=UNKNOWN_TASK_ID)
    if "state" not in stale:
        errors.append("an unknown task id does not fall back to a documented state marker")
    for field in ("stage", "nextMode", "command"):
        if field in stale:
            errors.append(f"an unknown task id still carries {field!r}, so a stale stage can be executed")

    for status in NON_ROUTING_STATUSES:
        routing = mcp_context.transition({"id": SAMPLE_TASK_ID, "status": status})
        if routing.get("nextMode") is not None or routing.get("command") is not None:
            errors.append(f"{status}: still routes to a stage instead of stopping")
    unmapped = mcp_context.transition({"id": SAMPLE_TASK_ID, "status": UNMAPPED_STATUS})
    if unmapped.get("nextMode") is not None or unmapped.get("command") is not None:
        errors.append(f"unmapped status {UNMAPPED_STATUS!r} still routes to a stage")
    if mcp_context.stage({"status": UNMAPPED_STATUS}) != "unknown":
        errors.append(f"unmapped status {UNMAPPED_STATUS!r} does not fail to an 'unknown' stage")
    return errors


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv:
        print("unknown arguments: " + " ".join(argv), file=sys.stderr)
        return 2

    try:
        mcp_context = _import_context()
    except Exception as exc:
        _report("fresh-child pipeline smoke failed", [f"cannot import shipped MCP context module: {exc}"])
        return 1

    modes = _load_modes()
    declared = _mode_map(modes)
    if not any(slug.startswith(MODE_PREFIX) for slug in declared):
        _report("fresh-child pipeline smoke failed", ["no platforminit-* modes declared in .roomodes"])
        return 1
    roles = _role_modes(_platform_tasks())
    if not SMOKE_COMMAND.is_file():
        _report("fresh-child pipeline smoke failed", [f"{SMOKE_COMMAND.name} missing"])
        return 1
    smoke = SMOKE_COMMAND.read_text(encoding="utf-8")

    gate1 = gate1_errors(mcp_context, modes, roles, smoke)
    if gate1:
        _report("fresh-child pipeline smoke failed: gate 1 (fresh child per specialist stage)", gate1)
        return 1
    print(f"PASS: gate 1 - {len(STAGE_STATUS)} specialist stages route to declared fresh-child modes.")

    gate2 = gate2_errors(mcp_context, smoke, modes, roles)
    if gate2:
        _report("fresh-child pipeline smoke failed: gate 2 (MCP context after every handoff)", gate2)
        return 1
    print("PASS: gate 2 - every stage mode boots MCP health + get_delivery_context after a handoff.")

    gate3 = gate3_errors(mcp_context, smoke)
    if gate3:
        _report("fresh-child pipeline smoke failed: gate 3 (bounded handoff, no stale stage)", gate3)
        return 1
    print(
        f"PASS: gate 3 - handoff payload bounded to {HANDOFF_MAX_FIELDS} fields and no stale stage is routable."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
