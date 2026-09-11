# Deprecated: B02 switch-mode rehearsal

This rehearsal is superseded because PlatformInit no longer uses conversation-preserving Roo
`switch_mode` for delivery lifecycle stages.

Current workflow contract: [`PLATFORM_WORKFLOW_REFACTOR.md`](PLATFORM_WORKFLOW_REFACTOR.md)  
Current runtime mode/MCP smoke: [`.roo/commands/mcp-smoke.md`](../../.roo/commands/mcp-smoke.md)

The supported Zoo workflow starts each specialist as a fresh `new_task` child, calls MCP `health`
and `get_delivery_context`, and returns through `attempt_completion`. The Orchestrator reloads compact
MCP context between children.

Historical B02 artifacts must not be used as active delivery instructions.
