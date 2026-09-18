#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from typing import Any

from context import (
    BASE_ALLOWED_REFS,
    BASE_DEFAULT,
    BASE_MAX_LENGTH,
    CONTEXT_VERSION,
    InvalidToolInput,
    PROJECT,
    SCOPE_DEFAULT_FILES,
    SCOPE_HARD_CAP_FILES,
    TASK_ID_MAX_LENGTH,
    active_task_summary,
    changed_scope,
    delivery_context,
)

TOOLS = [
    {
        "name": "health",
        "description": "Minimal PlatformInit MCP availability check for Zoo mode-transition smoke tests.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "get_delivery_context",
        "description": "Return the compact platform-only PlatformInit delivery context: task, stage transition, and bounded changed scope.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "taskId": {"type": "string", "maxLength": TASK_ID_MAX_LENGTH},
                "base": {
                    "type": "string",
                    "enum": list(BASE_ALLOWED_REFS),
                    "maxLength": BASE_MAX_LENGTH,
                    "default": BASE_DEFAULT,
                },
                "maxFiles": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": SCOPE_HARD_CAP_FILES,
                    "default": SCOPE_DEFAULT_FILES,
                }
            },
            "additionalProperties": False
        }
    },
    {
        "name": "get_active_task",
        "description": "Return only the active or next runnable PlatformInit task.",
        "inputSchema": {
            "type": "object",
            "properties": {"taskId": {"type": "string", "maxLength": TASK_ID_MAX_LENGTH}},
            "additionalProperties": False
        }
    },
    {
        "name": "get_changed_scope",
        "description": "Return bounded non-state PlatformInit changed paths, focused-test hints, and small-task budget.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "base": {
                    "type": "string",
                    "enum": list(BASE_ALLOWED_REFS),
                    "maxLength": BASE_MAX_LENGTH,
                    "default": BASE_DEFAULT,
                },
                "maxFiles": {
                    "type": "integer",
                    "minimum": 1,
                    "maximum": SCOPE_HARD_CAP_FILES,
                    "default": SCOPE_DEFAULT_FILES,
                }
            },
            "additionalProperties": False
        }
    }
]


def result_text(value: Any) -> dict:
    return {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False, separators=(",", ":"))}]}


def rpc_result(message_id: Any, value: Any) -> dict:
    return {"jsonrpc": "2.0", "id": message_id, "result": value}


def rpc_error(message_id: Any, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}}


def allowed_arguments(name: object) -> set[str] | None:
    """Declared argument names for a tool, taken from the schema so the two cannot drift."""
    for tool in TOOLS:
        if tool["name"] == name:
            return set(tool.get("inputSchema", {}).get("properties", {}))
    return None


def handle(message: dict) -> dict | None:
    if not isinstance(message, dict):
        return rpc_error(None, -32600, "invalid request: message must be a JSON object")

    method = message.get("method")
    message_id = message.get("id")
    params = message.get("params")
    if params is None:
        params = {}
    if not isinstance(params, dict):
        return rpc_error(message_id, -32602, "invalid params: 'params' must be an object")

    if method == "initialize":
        return rpc_result(message_id, {
            "protocolVersion": params.get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "platforminit-roo-lab", "version": "0.3.0"}
        })
    if method == "notifications/initialized":
        return None
    if method == "ping":
        return rpc_result(message_id, {})
    if method == "tools/list":
        return rpc_result(message_id, {"tools": TOOLS})
    if method == "tools/call":
        name = params.get("name")
        declarable = allowed_arguments(name)
        if declarable is None:
            return rpc_error(message_id, -32602, "invalid params: unknown tool")
        arguments = params.get("arguments")
        if arguments is None:
            arguments = {}
        if not isinstance(arguments, dict):
            return rpc_error(message_id, -32602, "invalid params: 'arguments' must be an object")
        if set(arguments) - declarable:
            return rpc_error(message_id, -32602, "invalid params: unexpected argument name")
        try:
            if name == "health":
                value = {"ok": True, "project": PROJECT, "contextVersion": CONTEXT_VERSION}
            elif name == "get_delivery_context":
                value = delivery_context(
                    task_id=arguments.get("taskId"),
                    base=arguments.get("base", BASE_DEFAULT),
                    max_files=arguments.get("maxFiles", SCOPE_DEFAULT_FILES),
                )
            elif name == "get_active_task":
                value = active_task_summary(task_id=arguments.get("taskId"))
            else:
                value = changed_scope(
                    base=arguments.get("base", BASE_DEFAULT),
                    max_files=arguments.get("maxFiles", SCOPE_DEFAULT_FILES),
                )
            return rpc_result(message_id, result_text(value))
        except InvalidToolInput as exc:
            # Controlled rejection: the message is constant text and carries no host path.
            return rpc_error(message_id, -32602, f"invalid params: {exc}")
        except Exception:
            # Never echo exception text: it can carry host paths or Git output.
            return rpc_error(message_id, -32603, "internal tool error")
    return rpc_error(message_id, -32601, "method not found")


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            response = rpc_error(None, -32700, "parse error: invalid JSON")
        else:
            response = handle(payload)
        if response is not None:
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
