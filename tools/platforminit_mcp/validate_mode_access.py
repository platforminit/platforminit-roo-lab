#!/usr/bin/env python3
from __future__ import annotations

import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
MODES = ROOT / ".roomodes"
MCP = ROOT / ".roo" / "mcp.json"
REQUIRED_TOOLS = {"health", "get_delivery_context", "get_active_task", "get_changed_scope"}


def main() -> int:
    errors: list[str] = []
    modes = json.loads(MODES.read_text(encoding="utf-8")).get("customModes", [])
    platform_modes = [mode for mode in modes if mode.get("slug", "").startswith("platforminit-")]
    if not platform_modes:
        errors.append("no platforminit-* project modes found")
    for mode in platform_modes:
        groups = mode.get("groups", [])
        if "mcp" not in groups:
            errors.append(f"{mode.get('slug')}: missing mcp group")
        instructions = mode.get("customInstructions", "")
        if "get_delivery_context" not in instructions and mode.get("slug") != "platforminit-orchestrator":
            errors.append(f"{mode.get('slug')}: instructions do not load compact delivery context")

    mcp = json.loads(MCP.read_text(encoding="utf-8"))
    servers = mcp.get("mcpServers", {})
    server = servers.get("platforminit-roo-lab")
    if not server:
        errors.append("platforminit-roo-lab MCP server missing")
    else:
        allowed = set(server.get("alwaysAllow", []))
        missing = sorted(REQUIRED_TOOLS - allowed)
        if missing:
            errors.append("MCP alwaysAllow missing: " + ", ".join(missing))
        if server.get("disabled") is True:
            errors.append("PlatformInit MCP server is disabled")

    if errors:
        print("MCP mode access validation failed:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1
    print(f"PASS: {len(platform_modes)} PlatformInit modes declare MCP access and required tools are enabled.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
