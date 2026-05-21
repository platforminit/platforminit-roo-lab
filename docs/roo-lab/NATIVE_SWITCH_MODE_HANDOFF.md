
<!-- PLATFORMINIT_NATIVE_SWITCH_MODE_HANDOFF_START -->
# Native Roo Mode-Switch Handoff

PlatformInit Roo Lab uses native Roo mode switching for role-to-role handoff.

Manual prompt copying is not the normal workflow.

## Required lifecycle

```text
PlatformInit Orchestrator
  -> switch_mode: platforminit-deepseek-coder

PlatformInit DeepSeek Coder
  -> switch_mode: platforminit-openai-reviewer

PlatformInit OpenAI Reviewer
  APPROVE -> switch_mode: platforminit-owasp-reviewer
  REQUEST_CHANGES -> switch_mode: platforminit-deepseek-coder

PlatformInit OWASP Reviewer
  PASS -> switch_mode: platforminit-release-manager
  MUST_FIX -> switch_mode: platforminit-deepseek-coder

PlatformInit Release Manager
  -> final human commit/PR/merge handoff
```

## Fallback

If native mode switching is unavailable or blocked, the role must explicitly report:

```text
SWITCH_MODE_UNAVAILABLE_FALLBACK_USED
```

Only then may it print the next role prompt.

## Hard gates

Native role switching does not remove human approval gates.

Human approval remains mandatory before:

- CH01-CH05 workflow execution;
- infrastructure mutation;
- GitHub secret or environment mutation;
- production/customer scope;
- Hetzner, Cloudflare, Kubernetes, Authentik, Checkmk, DNS, k3s, or n8n runtime changes.
<!-- PLATFORMINIT_NATIVE_SWITCH_MODE_HANDOFF_END -->
