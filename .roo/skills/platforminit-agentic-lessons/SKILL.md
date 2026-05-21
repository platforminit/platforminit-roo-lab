---
name: platforminit-agentic-lessons
description: Use when designing Roo tasks, custom modes, validation gates, or when a task resembles the failed Peximed agentic workflow.
---


# PlatformInit Agentic Lessons Skill

## Peximed lessons

The agentic workflow failed when the system had:

- insufficient source-of-truth discipline;
- task prompts not matching the real codebase;
- premature review/security phases;
- stale validation state;
- unclear branch ownership;
- too much frontend/product drift;
- weak handoff and closeout.

## PlatformInit rules

- Active task must be self-contained.
- Branch must be checked before work.
- Roo must not infer stack from old prompts.
- Architect must approve roadmap or product pivots.
- Review must be changed-files-only unless full review is requested.
- OWASP is read-only unless explicitly approved.
- Validation stale/unavailable is a blocker, not a prompt to continue.
- Closeout must update next active task.
