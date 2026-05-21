# PlatformInit Roo Agent Operating Layer v2

## Purpose

This layer gives the `platforminit-roo-lab` repository a dedicated PlatformInit agent team before any full-access dev workflow execution.

It is built from four inputs:

1. the current PlatformInit/Homelab memory baseline;
2. the CH01-CH15 full roadmap;
3. Roo Code compatibility lessons;
4. Peximed failure lessons.

The Claude-generated package was used only as a structural reference. The final rules prefer the current PlatformInit context, the Checkmk CH05 direction, WSL-only execution, dev branch discipline, and batch-based review gates.

## Why v2 exists

The first agent-layer draft was useful but incomplete:

- it did not embed the full roadmap context;
- it did not include a curated memory baseline;
- it did not explicitly encode Peximed failure lessons;
- some role rules were too generic;
- some older Zabbix/OpenObserve references could be mistaken for current active direction.

v2 adds a stronger architect layer, richer skills, current-state context docs, and a clear rule that archived memory must not automatically override current repo state.

## Operating principle

Do not let Roo be a generic coding assistant. Treat Roo as a small platform engineering team:

| Mode | Primary job |
|---|---|
| Orchestrator | sequence and gate work |
| Architect | decide boundaries and architecture |
| DeepSeek Coder | implement bounded patches |
| OpenAI Reviewer | changed-files review |
| OWASP Reviewer | read-only security review |
| SRE Diagnostics | evidence and RCA |
| Release Manager | known-good checkpoints |
| Docs Operator | runbooks and handoffs |

## First use

The first run must validate the agent layer only.

No infrastructure workflow should be triggered until:

- `.roomodes` loads;
- skills are discoverable;
- WSL guard passes;
- branch is `batch/roo-lab-first-validation`;
- repo-visible org secrets are confirmed by name only;
- GitHub environments `development` and `n8n` exist;
- active task and rules are consistent.
