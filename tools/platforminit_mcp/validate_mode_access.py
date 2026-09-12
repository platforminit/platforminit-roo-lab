#!/usr/bin/env python3
"""Verify that every PlatformInit Zoo mode keeps working MCP access.

Static layer (default, cheap, no subprocess side effects):
  - every `platforminit-*` mode declares the `mcp` tool group;
  - every mode bootstraps from MCP delivery context as a fresh child, so mode changes never
    depend on conversation-carried context;
  - `.roo/commands/mcp-smoke.md` documents exactly the modes declared in `.roomodes` (no drift);
  - the `platforminit-roo-lab` server is enabled and always-allows the required tools;
  - the shipped server actually exposes the required tools;
  - the delivery-context contract stays platform-only, keeps the changed-scope window bounded for
    small tasks, and advertises that bound in the tool schema.

Runtime layer (`--runtime`): boots the stdio JSON-RPC server exactly like Zoo does and calls
`health`, `get_active_task`, `get_delivery_context`, and an oversized `get_changed_scope` request,
asserting the returned task id matches authoritative tracker state, that delivery context holds only
stage-critical fields, and that the changed-scope hard cap is enforced.

Usage:
  python3 tools/platforminit_mcp/validate_mode_access.py
  python3 tools/platforminit_mcp/validate_mode_access.py --runtime
"""
from __future__ import annotations

import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
MODES = ROOT / ".roomodes"
MCP = ROOT / ".roo" / "mcp.json"
SMOKE_COMMAND = ROOT / ".roo" / "commands" / "mcp-smoke.md"
TRACKER = ROOT / "tasks" / "tracker.json"
SERVER = Path(__file__).resolve().parent / "server.py"
REQUIRED_TOOLS = {"health", "get_delivery_context", "get_active_task", "get_changed_scope"}
FRESH_CHILD_MARKERS = ("child start", "fresh child")
ACTIVE_STATES = {"in_progress", "needs_review", "needs_security_review", "ready_to_close"}
RUNTIME_TIMEOUT_SECONDS = 120

# Compact delivery-context contract (P-WF-T03): platform-only, bounded for small tasks, and limited
# to stage-critical fields. These sets are declared here so field drift fails loudly.
PLATFORM_TRACK = "platform"
DELIVERY_CONTEXT_KEYS = {
    "contextVersion",
    "project",
    "track",
    "task",
    "scope",
    "handoff",
    "authoritativeTaskSource",
}
TASK_SUMMARY_KEYS = {
    "id",
    "track",
    "status",
    "title",
    "scope",
    "branch",
    "dependsOn",
    "acceptanceCriteria",
    "allowedFiles",
    "requiredValidators",
    "forbiddenActions",
    "stage",
    "nextMode",
    "command",
}
SCOPE_KEYS = {
    "base",
    "platformOnly",
    "fileCount",
    "files",
    "truncated",
    "focusedTests",
    "foreignPathsExcluded",
    "budget",
}
SCOPE_HARD_CAP = 8
SCOPE_DEFAULT_LIMIT = 5
FOREIGN_TRACK_PREFIXES = ("n8n/", "docs/n8n/")


def _report(title: str, errors: list[str]) -> None:
    print(title + ":", file=sys.stderr)
    for error in errors:
        print(f"- {error}", file=sys.stderr)


def _load_modes() -> list[dict]:
    return json.loads(MODES.read_text(encoding="utf-8")).get("customModes", [])


def _platform_modes(modes: list[dict]) -> list[dict]:
    return [mode for mode in modes if mode.get("slug", "").startswith("platforminit-")]


def _served_tools() -> set[str]:
    """Tool names exposed by the shipped MCP server, discovered without side effects."""
    sys.path.insert(0, str(SERVER.parent))
    try:
        import server  # type: ignore[import-not-found]  # path-scoped import of the shipped server

        return {tool.get("name") for tool in server.TOOLS}
    except Exception:
        return set()
    finally:
        sys.path.pop(0)


def delivery_contract_errors() -> list[str]:
    """Static, subprocess-free checks of the compact delivery-context contract."""
    sys.path.insert(0, str(SERVER.parent))
    try:
        import context as mcp_context  # type: ignore[import-not-found]
        import server as mcp_server  # type: ignore[import-not-found]
    except Exception as exc:
        return [f"cannot import shipped MCP modules: {exc}"]
    finally:
        sys.path.pop(0)

    errors: list[str] = []
    if mcp_context.PLATFORM_TRACK != PLATFORM_TRACK:
        errors.append(f"delivery context is not platform-only: {mcp_context.PLATFORM_TRACK!r}")
    if not mcp_context.FOREIGN_TRACK_PATHS:
        errors.append("delivery context excludes no foreign-track paths")
    if mcp_context.SCOPE_HARD_CAP_FILES != SCOPE_HARD_CAP:
        errors.append(
            f"changed-scope hard cap is not bounded for small tasks: {mcp_context.SCOPE_HARD_CAP_FILES}"
        )
    if mcp_context.SCOPE_DEFAULT_FILES > SCOPE_DEFAULT_LIMIT:
        errors.append(
            f"changed-scope default is not bounded for small tasks: {mcp_context.SCOPE_DEFAULT_FILES}"
        )
    if mcp_context.SCOPE_DEFAULT_FILES > mcp_context.SCOPE_HARD_CAP_FILES:
        errors.append("changed-scope default exceeds the hard cap")
    if mcp_context.clamp_max_files(None) != mcp_context.SCOPE_DEFAULT_FILES:
        errors.append("changed-scope clamp does not fall back to the small-task default")
    if mcp_context.clamp_max_files(10**6) != mcp_context.SCOPE_HARD_CAP_FILES:
        errors.append("changed-scope clamp does not enforce the hard cap")

    for tool in mcp_server.TOOLS:
        properties = tool.get("inputSchema", {}).get("properties", {})
        if "maxFiles" not in properties:
            continue
        schema = properties["maxFiles"]
        if schema.get("maximum") != mcp_context.SCOPE_HARD_CAP_FILES:
            errors.append(f"{tool.get('name')}: maxFiles schema does not advertise the hard cap")
        if schema.get("default") != mcp_context.SCOPE_DEFAULT_FILES:
            errors.append(f"{tool.get('name')}: maxFiles schema does not advertise the small-task default")
    return errors


def static_errors() -> tuple[list[str], list[dict]]:
    errors: list[str] = []
    modes = _load_modes()
    platform_modes = _platform_modes(modes)
    if not platform_modes:
        errors.append("no platforminit-* project modes found")

    for mode in platform_modes:
        slug = mode.get("slug")
        if "mcp" not in mode.get("groups", []):
            errors.append(f"{slug}: missing mcp group")
        instructions = mode.get("customInstructions", "")
        if "get_delivery_context" not in instructions:
            errors.append(f"{slug}: instructions do not load compact delivery context")
        if "health" not in instructions:
            errors.append(f"{slug}: instructions do not call MCP health")
        if not any(marker in instructions for marker in FRESH_CHILD_MARKERS):
            errors.append(f"{slug}: instructions do not start as a fresh child")

    if not SMOKE_COMMAND.is_file():
        errors.append(".roo/commands/mcp-smoke.md missing")
    else:
        smoke = SMOKE_COMMAND.read_text(encoding="utf-8")
        for mode in platform_modes:
            if f"`{mode['slug']}`" not in smoke:
                errors.append(f"{mode['slug']}: not documented in .roo/commands/mcp-smoke.md")
        declared = {mode.get("slug") for mode in modes}
        for slug in re.findall(r"`(platforminit-[a-z0-9-]+)`", smoke):
            if slug not in declared:
                errors.append(f".roo/commands/mcp-smoke.md references unknown mode: {slug}")

    server = json.loads(MCP.read_text(encoding="utf-8")).get("mcpServers", {}).get("platforminit-roo-lab")
    if not server:
        errors.append("platforminit-roo-lab MCP server missing")
    else:
        missing = sorted(REQUIRED_TOOLS - set(server.get("alwaysAllow", [])))
        if missing:
            errors.append("MCP alwaysAllow missing: " + ", ".join(missing))
        if server.get("disabled") is True:
            errors.append("PlatformInit MCP server is disabled")

    unexposed = sorted(REQUIRED_TOOLS - _served_tools())
    if unexposed:
        errors.append("MCP server does not expose: " + ", ".join(unexposed))

    errors.extend(delivery_contract_errors())

    return errors, platform_modes


def _expected_platform_task_id() -> str | None:
    tasks = [
        task for task in json.loads(TRACKER.read_text(encoding="utf-8"))["tasks"] if task.get("track") == "platform"
    ]
    mapping = {task["id"]: task for task in tasks}
    active = sorted(
        (task for task in tasks if task["status"] in ACTIVE_STATES),
        key=lambda task: (task["order"], task["id"]),
    )
    if active:
        return active[0]["id"]
    runnable = sorted(
        (
            task
            for task in tasks
            if task["status"] == "pending" and all(mapping[dep]["status"] == "done" for dep in task["dependsOn"])
        ),
        key=lambda task: (task["order"], task["id"]),
    )
    return runnable[0]["id"] if runnable else None


def _tool_payload(message: dict) -> dict:
    return json.loads(message["result"]["content"][0]["text"])


def runtime_errors() -> list[str]:
    errors: list[str] = []
    requests: list[dict | None] = [
        {
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "validate_mode_access", "version": "0.1.0"},
            },
        },
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "health", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "get_active_task", "arguments": {}}},
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call", "params": {"name": "get_delivery_context", "arguments": {}}},
        {
            "jsonrpc": "2.0",
            "id": 6,
            "method": "tools/call",
            "params": {"name": "get_changed_scope", "arguments": {"maxFiles": 1000000}},
        },
    ]
    payload = "".join(json.dumps(request, separators=(",", ":")) + "\n" for request in requests if request)
    try:
        completed = subprocess.run(
            [sys.executable, str(SERVER)],
            cwd=str(SERVER.parent),
            input=payload,
            text=True,
            capture_output=True,
            timeout=RUNTIME_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return [f"runtime smoke: MCP server did not answer within {RUNTIME_TIMEOUT_SECONDS}s"]
    if completed.returncode != 0:
        return [f"runtime smoke: MCP server exited {completed.returncode}: {completed.stderr.strip()}"]

    responses: dict[int, dict] = {}
    for line in completed.stdout.splitlines():
        if not line.strip():
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            errors.append("runtime smoke: non-JSON line on stdout")
            continue
        if message.get("id") is not None:
            responses[message["id"]] = message

    for message_id, label in (
        (1, "initialize"),
        (2, "tools/list"),
        (3, "health"),
        (4, "get_active_task"),
        (5, "get_delivery_context"),
        (6, "get_changed_scope"),
    ):
        if message_id not in responses:
            errors.append(f"runtime smoke: no response for {label}")
    if errors:
        return errors

    if responses[1]["result"].get("serverInfo", {}).get("name") != "platforminit-roo-lab":
        errors.append("runtime smoke: unexpected serverInfo name")
    exposed = {tool.get("name") for tool in responses[2]["result"].get("tools", [])}
    if not REQUIRED_TOOLS <= exposed:
        errors.append("runtime smoke: tools/list missing: " + ", ".join(sorted(REQUIRED_TOOLS - exposed)))

    health = _tool_payload(responses[3])
    if health.get("ok") is not True:
        errors.append(f"runtime smoke: health not ok: {health}")

    task = _tool_payload(responses[4])
    expected = _expected_platform_task_id()
    if task.get("id") != expected:
        errors.append(f"runtime smoke: get_active_task returned {task.get('id')} expected {expected}")

    delivery = _tool_payload(responses[5])
    drifted = sorted(set(delivery) ^ DELIVERY_CONTEXT_KEYS)
    if drifted:
        errors.append("runtime smoke: delivery context fields drifted: " + ", ".join(drifted))
    if delivery.get("track") != PLATFORM_TRACK:
        errors.append(f"runtime smoke: delivery context is not platform-only: {delivery.get('track')!r}")
    if "indexing" in delivery:
        errors.append("runtime smoke: delivery context carries non stage-critical indexing hints")
    summary = delivery.get("task", {})
    if "id" in summary:
        summary_drift = sorted(set(summary) ^ TASK_SUMMARY_KEYS)
        if summary_drift:
            errors.append("runtime smoke: task summary fields drifted: " + ", ".join(summary_drift))
    elif "state" not in summary:
        errors.append("runtime smoke: task summary is neither a task nor a documented state marker")
    scope = delivery.get("scope", {})
    scope_drift = sorted(set(scope) ^ SCOPE_KEYS)
    if scope_drift:
        errors.append("runtime smoke: changed-scope fields drifted: " + ", ".join(scope_drift))
    if scope.get("platformOnly") is not True:
        errors.append("runtime smoke: changed scope is not marked platform-only")
    foreign = [
        file
        for file in scope.get("files", [])
        if any(file.startswith(prefix) for prefix in FOREIGN_TRACK_PREFIXES)
    ]
    if foreign:
        errors.append("runtime smoke: foreign-track paths in delivery scope: " + ", ".join(foreign))
    for label, payload in (("get_delivery_context", scope), ("get_changed_scope", _tool_payload(responses[6]))):
        if len(payload.get("files", [])) > SCOPE_HARD_CAP:
            errors.append(f"runtime smoke: {label} exceeded the {SCOPE_HARD_CAP}-file changed-scope hard cap")
        if payload.get("platformOnly") is not True:
            errors.append(f"runtime smoke: {label} is not marked platform-only")

    return errors


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    unknown = [arg for arg in argv if arg != "--runtime"]
    if unknown:
        print("unknown arguments: " + " ".join(unknown), file=sys.stderr)
        return 2

    errors, platform_modes = static_errors()
    if errors:
        _report("MCP mode access validation failed", errors)
        return 1
    print(f"PASS: {len(platform_modes)} PlatformInit modes declare MCP access and required tools are enabled.")

    if "--runtime" not in argv:
        return 0

    runtime_failures = runtime_errors()
    if runtime_failures:
        _report("MCP runtime smoke failed", runtime_failures)
        return 1
    print("PASS: runtime MCP smoke health/get_active_task returned the authoritative PlatformInit task.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
