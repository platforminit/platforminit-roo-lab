# PlatformInit Multi-Track Task Orchestration Model

PlatformInit Roo Lab uses explicit roadmap-backed task orchestration.

## Tracks

| Track | Purpose | Next task |
|---|---|---|
| `platform` | Main PlatformInit CH01-CH15 roadmap | `tasks/active/platform/NEXT_TASK.md` |
| `n8n` | Standalone n8n host/runtime/workflow roadmap | `tasks/active/n8n/NEXT_TASK.md` |

## Source of truth

Roadmap source files:

- `tasks/roadmap/platform.json`
- `tasks/roadmap/n8n.json`

Status files:

- `tasks/status/platform.json`
- `tasks/status/n8n.json`

Active task files:

- `tasks/active/platform/NEXT_TASK.md`
- `tasks/active/n8n/NEXT_TASK.md`

Top-level `tasks/active/NEXT_TASK.md` is only an index. Roo must use the track-specific NEXT_TASK for execution.

## Start rule

Human or Roo starts a task with:

```bash
./scripts/orchestrator/start-next-task.sh --track platform
```

or:

```bash
./scripts/orchestrator/start-next-task.sh --track n8n
```

The script verifies WSL runtime, requires a clean working tree, generates the track-specific `NEXT_TASK.md`, creates or switches to the required branch, and pushes the branch upstream if possible.

## Closeout rule

Release Manager closes the current task with:

```bash
./scripts/orchestrator/close-current-task.sh --track platform --task PLATFORM-CH01-T01
```

or:

```bash
./scripts/orchestrator/close-current-task.sh --track n8n --task N8N-CH01-T01
```

The closeout script marks the task complete and regenerates the next task for the same track.

## n8n separation

n8n has its own roadmap and its own next task because it is a standalone host/runtime/workflow track.

The n8n track must not be silently mixed into the main PlatformInit CH01-CH15 track.
