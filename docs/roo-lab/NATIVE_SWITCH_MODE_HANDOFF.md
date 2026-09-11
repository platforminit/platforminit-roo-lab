# Deprecated: native Roo switch-mode handoff

This document is historical. PlatformInit no longer uses conversation-preserving Roo `switch_mode`
for delivery lifecycle handoffs because accumulated context repeatedly caused Zoo/API HTTP 400 failures.

Current contract: [`PLATFORM_WORKFLOW_REFACTOR.md`](PLATFORM_WORKFLOW_REFACTOR.md).

The supported flow is native Zoo `new_task`: every implementation, review, security, rework, and
release stage starts as a fresh child with MCP compact context. The child returns through
`attempt_completion`; the Orchestrator reloads MCP context before starting the next stage.

Do not restore the old switch-mode lifecycle without an explicit human architecture decision.
