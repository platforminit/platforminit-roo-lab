#!/usr/bin/env python3
from __future__ import annotations

import json
import sys
from typing import Any

from context import active_task_summary, changed_scope, delivery_context

TOOLS = [
    {
        "name": "get_delivery_context",
        "description": "Return active/next task, transition, bounded changed scope, validators, and indexed-search hints in one compact call.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "track": {"type": "string", "enum": ["platform", "n8n"]},
                "taskId": {"type": "string"},
                "base": {"type": "string", "default": "dev"},
                "maxFiles": {"type": "integer", "minimum": 1, "maximum": 80, "default": 40}
            },
            "additionalProperties": False
        }
    },
    {
        "name": "get_active_task",
        "description": "Return only the active or next runnable task from the canonical tracker.",
        "inputSchema": {
            "type": "object",
            "properties": {"track": {"type": "string", "enum": ["platform", "n8n"]}, "taskId": {"type": "string"}},
            "additionalProperties": False
        }
    },
    {
        "name": "get_changed_scope",
        "description": "Return changed paths and focused-test hints without loading repository-wide context.",
        "inputSchema": {
            "type": "object",
            "properties": {"base": {"type": "string", "default": "dev"}, "maxFiles": {"type": "integer", "minimum": 1, "maximum": 80, "default": 40}},
            "additionalProperties": False
        }
    }
]


def result_text(value: Any) -> dict:
    return {"content": [{"type": "text", "text": json.dumps(value, ensure_ascii=False)}]}


def rpc_result(message_id: Any, value: Any) -> dict:
    return {"jsonrpc": "2.0", "id": message_id, "result": value}


def rpc_error(message_id: Any, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": message_id, "error": {"code": code, "message": message}}


def handle(message: dict) -> dict | None:
    method = message.get("method")
    message_id = message.get("id")
    params = message.get("params") or {}

    if method == "initialize":
        return rpc_result(message_id, {
            "protocolVersion": params.get("protocolVersion", "2025-06-18"),
            "capabilities": {"tools": {}},
            "serverInfo": {"name": "platforminit-roo-lab", "version": "0.1.0"}
        })
    if method == "notifications/initialized":
        return None
    if method == "ping":
        return rpc_result(message_id, {})
    if method == "tools/list":
        return rpc_result(message_id, {"tools": TOOLS})
    if method == "tools/call":
        name = params.get("name")
        arguments = params.get("arguments") or {}
        try:
            if name == "get_delivery_context":
                value = delivery_context(
                    track=arguments.get("track"),
                    task_id=arguments.get("taskId"),
                    base=arguments.get("base", "dev"),
                    max_files=arguments.get("maxFiles", 40),
                )
            elif name == "get_active_task":
                value = active_task_summary(track=arguments.get("track"), task_id=arguments.get("taskId"))
            elif name == "get_changed_scope":
                value = changed_scope(base=arguments.get("base", "dev"), max_files=arguments.get("maxFiles", 40))
            else:
                return rpc_error(message_id, -32602, f"unknown tool: {name}")
            return rpc_result(message_id, result_text(value))
        except Exception as exc:
            return rpc_result(message_id, {"content": [{"type": "text", "text": str(exc)}], "isError": True})
    return rpc_error(message_id, -32601, f"method not found: {method}")


def main() -> int:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            response = handle(json.loads(line))
        except json.JSONDecodeError as exc:
            response = rpc_error(None, -32700, f"parse error: {exc}")
        if response is not None:
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
