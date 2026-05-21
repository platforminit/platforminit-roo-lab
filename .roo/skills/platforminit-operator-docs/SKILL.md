---
name: platforminit-operator-docs
description: Use when writing runbooks, handoffs, task docs, operator prompts, or VS Code/WSL instructions.
---


# PlatformInit Operator Docs Skill

## Style

- Hungarian or English is acceptable; match the operator context.
- Prefer WSL-native commands.
- Avoid PowerShell/CMD.
- Include exact repo path.
- Include expected output.
- Include stop conditions.
- Include recovery path.

## Good structure

```text
Purpose
Scope
Prerequisites
Commands
Expected output
Failure modes
Recovery
Next step
```

## Handoff quality bar

A new chat/agent should be able to continue from the handoff without guessing:

- branch;
- repo path;
- task;
- current status;
- changed files;
- validation;
- risks;
- next command.
