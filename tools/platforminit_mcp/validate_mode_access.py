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
    small tasks, and advertises that bound in the tool schema;
  - every caller-supplied tool argument is bounded before it can reach a Git argument vector or a
    tracker lookup, and every rejection is a controlled JSON-RPC error without host paths.

Runtime layer (`--runtime`): boots the stdio JSON-RPC server exactly like Zoo does and calls
`health`, `get_active_task`, `get_delivery_context`, and an oversized `get_changed_scope` request,
asserting the returned task id matches authoritative tracker state, that delivery context holds only
stage-critical fields, and that the changed-scope hard cap is enforced. It also replays the bounded
tool-input rejection matrix (oversized, option-like, `..`, unsupported, and non-string `base`;
non-integer or boolean `maxFiles`; oversized or non-string `taskId`; unknown tool; unexpected,
non-object, and non-object-`params` arguments, plus malformed JSON) and asserts every case is a
controlled JSON-RPC error whose message carries no host path and no traceback.

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
REQUIRED_TOOLS = {"health", "get_delivery_context", "get_active_task", "get_changed_scope", "get_relevant_memory"}
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

# Bounded tool inputs (P-WF-T03 M-01 security rework). Every caller-supplied argument must be
# constrained before it can reach a Git argument vector or a tracker lookup, and every rejection must
# be a controlled JSON-RPC error whose message carries neither a traceback nor a host path.
BASE_MAX_LENGTH_LIMIT = 64
RPC_INVALID_PARAMS = -32602
RPC_PARSE_ERROR = -32700
TRACEBACK_MARKER = "Traceback"
HOST_PATH_MARKERS = ("/mnt/", "/home/", "/root/", "platforminit-roo-lab")
VALID_BASE = "dev"
EXAMPLE_VALID_TASK_ID = "P-WF-T03"

INVALID_BASE_INPUTS: tuple[tuple[str, object], ...] = (
    ("oversized", VALID_BASE + "a" * (BASE_MAX_LENGTH_LIMIT + 8)),
    ("option-like", "--upload-pack=git-upload-pack"),
    ("ref-with-dotdot", "dev..main"),
    ("unsupported-ref", "origin/feature-x"),
    ("non-string", 7),
    ("empty", ""),
    ("non-ref-characters", "dev; rm -rf /"),
)
INVALID_MAX_FILES_INPUTS: tuple[tuple[str, object], ...] = (
    ("non-integer-string", "5"),
    ("float", 2.5),
    ("boolean", True),
    ("list", [3]),
)
INVALID_TASK_ID_INPUTS: tuple[tuple[str, object], ...] = (
    ("non-string", 7),
    ("oversized", "T" * (BASE_MAX_LENGTH_LIMIT + 8)),
    ("non-id-characters", EXAMPLE_VALID_TASK_ID + "; rm -rf /"),
)

# Runtime rejection matrix: each call must come back as a controlled JSON-RPC error, never a
# traceback and never a message that leaks a host path.
INVALID_RUNTIME_CALLS: tuple[tuple[int, str, dict], ...] = (
    (101, "oversized base", {"name": "get_delivery_context", "arguments": {"base": VALID_BASE + "a" * 200}}),
    (102, "option-like base", {"name": "get_changed_scope", "arguments": {"base": "--upload-pack=calc"}}),
    (103, "ref-with-dotdot base", {"name": "get_changed_scope", "arguments": {"base": "dev..main"}}),
    (104, "unsupported ref base", {"name": "get_delivery_context", "arguments": {"base": "origin/feature-x"}}),
    (105, "non-string base", {"name": "get_changed_scope", "arguments": {"base": 5}}),
    (106, "non-integer maxFiles", {"name": "get_changed_scope", "arguments": {"maxFiles": "5"}}),
    (107, "boolean maxFiles", {"name": "get_delivery_context", "arguments": {"maxFiles": True}}),
    (108, "unknown tool", {"name": "get_everything", "arguments": {}}),
    (
        109,
        "unexpected argument",
        {"name": "get_active_task", "arguments": {"taskId": EXAMPLE_VALID_TASK_ID, "base": VALID_BASE}},
    ),
    (110, "non-string taskId", {"name": "get_active_task", "arguments": {"taskId": 7}}),
    (111, "oversized taskId", {"name": "get_delivery_context", "arguments": {"taskId": "T" * 200}}),
    (112, "non-object arguments", {"name": "get_changed_scope", "arguments": ["base"]}),
    (113, "memory non-string query", {"name": "get_relevant_memory", "arguments": {"query": 7}}),
    (
        114,
        "memory oversized query",
        {"name": "get_relevant_memory", "arguments": {"query": "x" * 600}},
    ),
    (115, "memory boolean maxItems", {"name": "get_relevant_memory", "arguments": {"maxItems": True}}),
    (116, "memory non-integer maxItems", {"name": "get_relevant_memory", "arguments": {"maxItems": "6"}}),
    (117, "memory unexpected argument", {"name": "get_relevant_memory", "arguments": {"base": VALID_BASE}}),
)
PARAMS_NOT_OBJECT_ID = 900
PARSE_ERROR_ID = 901


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
        import memory as mcp_memory  # type: ignore[import-not-found]
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

    memory_tool = next((tool for tool in mcp_server.TOOLS if tool.get("name") == "get_relevant_memory"), None)
    if memory_tool is None:
        errors.append("get_relevant_memory: tool schema missing")
    else:
        memory_properties = memory_tool.get("inputSchema", {}).get("properties", {})
        query_schema = memory_properties.get("query", {})
        item_schema = memory_properties.get("maxItems", {})
        if query_schema.get("maxLength") != mcp_memory.MAX_QUERY_LENGTH:
            errors.append("get_relevant_memory: query schema does not advertise the bounded maximum length")
        if item_schema.get("maximum") != mcp_memory.HARD_MAX_ITEMS:
            errors.append("get_relevant_memory: maxItems schema does not advertise the hard cap")
        if item_schema.get("default") != mcp_memory.DEFAULT_MAX_ITEMS:
            errors.append("get_relevant_memory: maxItems schema does not advertise the bounded default")

    errors.extend(bounded_input_errors(mcp_context, mcp_server))
    return errors


def _leaks_host_path(text: str) -> bool:
    """True when an error message would expose a host path or the workspace directory name."""
    return any(marker in text for marker in HOST_PATH_MARKERS)


def _controlled_rejection_errors(label: str, message: str, code: object) -> list[str]:
    """A rejection is only acceptable as a controlled invalid-params JSON-RPC error."""
    errors: list[str] = []
    if code != RPC_INVALID_PARAMS:
        errors.append(f"{label}: expected JSON-RPC code {RPC_INVALID_PARAMS}, got {code!r}")
    if not message.startswith("invalid params:"):
        errors.append(f"{label}: message is not a controlled invalid-params error: {message!r}")
    if TRACEBACK_MARKER in message:
        errors.append(f"{label}: message contains a traceback")
    if _leaks_host_path(message):
        errors.append(f"{label}: message leaks a host path")
    return errors


def bounded_input_errors(mcp_context, mcp_server) -> list[str]:
    """Static, subprocess-free checks of the bounded MCP tool-input contract (P-WF-T03 M-01).

    Every caller-supplied argument must be constrained before it can reach a Git argument vector or a
    tracker lookup, and every rejection must be a controlled JSON-RPC error. All calls made here fail
    validation before any Git subprocess starts, so this layer stays cheap and side-effect free.
    """
    errors: list[str] = []
    missing = [
        name
        for name in ("validate_base", "validate_task_id", "validate_max_files", "InvalidToolInput")
        if not hasattr(mcp_context, name)
    ]
    if missing:
        return ["MCP context module lacks bounded-input helpers: " + ", ".join(missing)]

    if not issubclass(mcp_context.InvalidToolInput, ValueError):
        errors.append("InvalidToolInput is not a ValueError subclass")
    if mcp_context.BASE_MAX_LENGTH > BASE_MAX_LENGTH_LIMIT:
        errors.append(f"base maximum length is not bounded: {mcp_context.BASE_MAX_LENGTH}")
    if not mcp_context.BASE_ALLOWED_REFS:
        errors.append("base allowlist is empty")
    if mcp_context.BASE_DEFAULT not in mcp_context.BASE_ALLOWED_REFS:
        errors.append("base default is not an allowlisted ref")

    for ref in mcp_context.BASE_ALLOWED_REFS:
        if ref.startswith("-") or ".." in ref or not mcp_context.BASE_REF_PATTERN.fullmatch(ref):
            errors.append(f"allowlisted ref is not a conservative Git ref: {ref!r}")
            continue
        try:
            if mcp_context.validate_base(ref) != ref:
                errors.append(f"validate_base does not round-trip allowlisted ref: {ref!r}")
        except Exception as exc:
            errors.append(f"validate_base rejected allowlisted ref {ref!r}: {type(exc).__name__}")

    for argument, validator, cases in (
        ("base", mcp_context.validate_base, INVALID_BASE_INPUTS),
        ("maxFiles", mcp_context.validate_max_files, INVALID_MAX_FILES_INPUTS),
        ("taskId", mcp_context.validate_task_id, INVALID_TASK_ID_INPUTS),
    ):
        for label, value in cases:
            try:
                accepted = validator(value)
            except mcp_context.InvalidToolInput as exc:
                message = str(exc)
                if _leaks_host_path(message):
                    errors.append(f"validate_{argument} {label}: rejection leaks a host path")
                if isinstance(value, str) and value and value in message:
                    errors.append(f"validate_{argument} {label}: rejection echoes caller input")
            except Exception as exc:
                errors.append(
                    f"validate_{argument} {label}: raised {type(exc).__name__} instead of InvalidToolInput"
                )
            else:
                errors.append(f"validate_{argument} {label}: accepted invalid input -> {accepted!r}")

    if mcp_context.validate_base(None) != mcp_context.BASE_DEFAULT:
        errors.append("validate_base does not fall back to the bounded default")
    if mcp_context.validate_task_id(None) is not None:
        errors.append("validate_task_id does not accept an omitted task id")
    if mcp_context.validate_max_files(None) != mcp_context.SCOPE_DEFAULT_FILES:
        errors.append("validate_max_files does not fall back to the small-task default")
    if mcp_context.validate_max_files(10**6) != mcp_context.SCOPE_HARD_CAP_FILES:
        errors.append("validate_max_files does not enforce the hard cap")
    if mcp_context.validate_max_files(0) != 1:
        errors.append("validate_max_files does not floor the changed-file window at 1")

    # No bypass path: every exported entry point that eventually reaches Git or a tracker lookup must
    # reject invalid input itself. These calls raise before any Git subprocess is started.
    for label, call in (
        ("delivery_context base", lambda: mcp_context.delivery_context(base="dev..main")),
        ("delivery_context maxFiles", lambda: mcp_context.delivery_context(max_files="5")),
        ("changed_scope base", lambda: mcp_context.changed_scope(base="--upload-pack=calc")),
        ("changed_scope maxFiles", lambda: mcp_context.changed_scope(max_files=[8])),
        ("active_task_summary taskId", lambda: mcp_context.active_task_summary(task_id=7)),
        ("select_task taskId", lambda: mcp_context.select_task(task_id="dev; rm -rf /")),
    ):
        try:
            call()
        except mcp_context.InvalidToolInput:
            continue
        except Exception as exc:
            errors.append(f"{label}: raised {type(exc).__name__} instead of InvalidToolInput")
        else:
            errors.append(f"{label}: accepted invalid input, so the bounded-input gate is bypassed")

    exposed = {tool.get("name"): tool for tool in mcp_server.TOOLS}
    for name in ("get_delivery_context", "get_changed_scope"):
        tool = exposed.get(name)
        if not tool:
            errors.append(f"{name}: tool schema missing")
            continue
        base_schema = tool.get("inputSchema", {}).get("properties", {}).get("base", {})
        if base_schema.get("enum") != list(mcp_context.BASE_ALLOWED_REFS):
            errors.append(f"{name}: base schema does not advertise the allowlisted refs")
        if base_schema.get("maxLength") != mcp_context.BASE_MAX_LENGTH:
            errors.append(f"{name}: base schema does not advertise the bounded maximum length")
        if base_schema.get("default") != mcp_context.BASE_DEFAULT:
            errors.append(f"{name}: base schema does not advertise the bounded default")

    for tool in mcp_server.TOOLS:
        schema = tool.get("inputSchema", {})
        if schema.get("additionalProperties") is not False:
            errors.append(f"{tool.get('name')}: schema does not reject undeclared arguments")
        task_schema = schema.get("properties", {}).get("taskId")
        if task_schema and task_schema.get("maxLength") != mcp_context.TASK_ID_MAX_LENGTH:
            errors.append(f"{tool.get('name')}: taskId schema does not advertise the bounded length")

    # JSON-RPC layer: rejections must be controlled errors, not exceptions escaping to the transport.
    rpc_cases: list[tuple[str, dict]] = [("unknown tool", {"name": "get_everything", "arguments": {}})]
    for label, value in INVALID_BASE_INPUTS[:4]:
        rpc_cases.append((f"{label} base", {"name": "get_changed_scope", "arguments": {"base": value}}))
    rpc_cases.append(("non-integer maxFiles", {"name": "get_changed_scope", "arguments": {"maxFiles": "5"}}))
    rpc_cases.append(("unexpected argument", {"name": "get_active_task", "arguments": {"base": VALID_BASE}}))
    for label, params in rpc_cases:
        response = mcp_server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": params})
        if not isinstance(response, dict) or "error" not in response:
            errors.append(f"JSON-RPC {label}: not rejected with a controlled error")
            continue
        error = response["error"]
        errors.extend(
            _controlled_rejection_errors(
                f"JSON-RPC {label}", str(error.get("message", "")), error.get("code")
            )
        )
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
        {
            "jsonrpc": "2.0",
            "id": 7,
            "method": "tools/call",
            "params": {
                "name": "get_relevant_memory",
                "arguments": {"query": "memory authority", "maxItems": 2},
            },
        },
    ]
    requests += [
        {"jsonrpc": "2.0", "id": message_id, "method": "tools/call", "params": params}
        for message_id, _label, params in INVALID_RUNTIME_CALLS
    ]
    lines = [json.dumps(request, separators=(",", ":")) for request in requests if request]
    lines += [
        # `params` is not an object.
        json.dumps(
            {"jsonrpc": "2.0", "id": PARAMS_NOT_OBJECT_ID, "method": "tools/call", "params": [VALID_BASE]},
            separators=(",", ":"),
        ),
        # Malformed JSON: must be answered with a controlled parse error, not a traceback.
        '{"jsonrpc":"2.0","id":%d,"method":"tools/call"' % PARSE_ERROR_ID,
    ]
    payload = "\n".join(lines) + "\n"
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

    if TRACEBACK_MARKER in completed.stdout or TRACEBACK_MARKER in completed.stderr:
        errors.append("runtime smoke: server emitted an unhandled exception traceback")

    responses: dict[int, dict] = {}
    id_less_responses: list[dict] = []
    for line in completed.stdout.splitlines():
        if not line.strip():
            continue
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            errors.append("runtime smoke: non-JSON line on stdout")
            continue
        if message.get("id") is None:
            id_less_responses.append(message)
        else:
            responses[message["id"]] = message

    expected_responses = [
        (1, "initialize"),
        (2, "tools/list"),
        (3, "health"),
        (4, "get_active_task"),
        (5, "get_delivery_context"),
        (6, "get_changed_scope"),
        (7, "get_relevant_memory"),
        (PARAMS_NOT_OBJECT_ID, "params not an object"),
    ] + [(message_id, label) for message_id, label, _params in INVALID_RUNTIME_CALLS]
    for message_id, label in expected_responses:
        if message_id not in responses:
            errors.append(f"runtime smoke: no response for {label}")
    if errors:
        return errors

    # Bounded-input rejection matrix: every invalid argument must come back as a controlled
    # invalid-params error without a traceback and without host-path leakage.
    for message_id, label, _params in INVALID_RUNTIME_CALLS:
        error = responses[message_id].get("error")
        if not isinstance(error, dict):
            errors.append(f"runtime smoke: {label} was not rejected with a controlled JSON-RPC error")
            continue
        errors.extend(
            _controlled_rejection_errors(
                f"runtime smoke: {label}", str(error.get("message", "")), error.get("code")
            )
        )

    params_error = responses[PARAMS_NOT_OBJECT_ID].get("error")
    if not isinstance(params_error, dict):
        errors.append("runtime smoke: non-object params were not rejected with a controlled error")
    else:
        errors.extend(
            _controlled_rejection_errors(
                "runtime smoke: params not an object",
                str(params_error.get("message", "")),
                params_error.get("code"),
            )
        )

    parse_error = next(
        (message["error"] for message in id_less_responses if isinstance(message.get("error"), dict)),
        None,
    )
    if not isinstance(parse_error, dict):
        errors.append("runtime smoke: malformed JSON input was not answered with a controlled parse error")
    else:
        parse_message = str(parse_error.get("message", ""))
        if parse_error.get("code") != RPC_PARSE_ERROR:
            errors.append(
                f"runtime smoke: malformed JSON returned code {parse_error.get('code')} instead of {RPC_PARSE_ERROR}"
            )
        if TRACEBACK_MARKER in parse_message or _leaks_host_path(parse_message):
            errors.append("runtime smoke: malformed JSON error message is not controlled")

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

    memory_payload = _tool_payload(responses[7])
    if memory_payload.get("advisoryOnly") is not True:
        errors.append("runtime smoke: relevant memory is not marked advisory-only")
    if memory_payload.get("authoritativeTaskSource") != "tasks/tracker.json":
        errors.append("runtime smoke: relevant memory changed the authoritative task source")
    if not isinstance(memory_payload.get("items"), list):
        errors.append("runtime smoke: relevant memory items are not a list")
    elif len(memory_payload["items"]) > 2:
        errors.append("runtime smoke: relevant memory exceeded requested maxItems=2")
    if memory_payload.get("itemCount") != len(memory_payload.get("items", [])):
        errors.append("runtime smoke: relevant memory itemCount does not match returned items")

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
