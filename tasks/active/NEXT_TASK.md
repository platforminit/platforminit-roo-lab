# Active Task Index

PlatformInit Roo Lab now uses separate active task tracks.

## Platform track

Read:

```text
tasks/active/platform/NEXT_TASK.md
```

Start:

```bash
./scripts/orchestrator/start-next-task.sh --track platform
```

## n8n track

Read:

```text
tasks/active/n8n/NEXT_TASK.md
```

Start:

```bash
./scripts/orchestrator/start-next-task.sh --track n8n
```

## Rule

Do not mix PlatformInit platform tasks and n8n standalone runtime tasks in the same branch.

Each track has its own roadmap, status file, and NEXT_TASK.
