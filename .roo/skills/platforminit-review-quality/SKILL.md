---
name: platforminit-review-quality
description: Use when reviewing changed files, writing reviewer prompts, or checking integration risk and acceptance criteria.
---


# PlatformInit Review Quality Skill

## Reviewer posture

The reviewer protects the platform from subtle regressions, not from formatting preferences.

## Review levels

| Level | Use |
|---|---|
| APPROVE | patch is scoped, validated, and safe |
| REQUEST_CHANGES | fixable issue blocks merge quality |
| BLOCK | security, data loss, wrong environment, or branch/scope violation |

## Required review areas

- scope creep;
- branch correctness;
- WSL-only commands;
- secret safety;
- idempotence;
- destructive operation guardrails;
- workflow inputs;
- artifact usefulness;
- CH boundary preservation;
- recovery path.

## Do not

- ask for broad refactor unrelated to task;
- rewrite the patch in review mode;
- hide blockers as suggestions;
- approve missing validation for infra changes.
