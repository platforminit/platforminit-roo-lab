# Retired task-state artifacts

PlatformInit previously stored mutable task state in both `tasks/status/*.json` and `tasks/roadmap/*.json`, with additional active Markdown sources such as `CURRENT_ACTIVE_TASKS.md` and `NEXT_TASK_AGENT_LAYER.md`.

Those paths are intentionally removed from the active tree. Their historical contents remain available through Git history and must not be restored as live task state.

Current authoritative state:

```text
tasks/tracker.json
```

Current generated views:

```text
tasks/active/NEXT_TASK.md
tasks/active/platform/NEXT_TASK.md
tasks/active/n8n/NEXT_TASK.md
```

If historical roadmap information is needed, read the relevant Git revision rather than copying it back into an authoritative-looking active path.
