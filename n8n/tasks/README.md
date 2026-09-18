# n8n standalone task registry

This directory holds the **n8n delivery track** task registry. It is deliberately separate from the
PlatformInit controller state in `tasks/tracker.json`.

- **Canonical roadmap:** [`docs/n8n/N8N_ROADMAP.md`](../../docs/n8n/N8N_ROADMAP.md)
- **Registry:** [`tracker.json`](tracker.json)
- **Track state:** parked — no n8n task may start without an explicit human resume decision.

## Ownership boundary

The n8n registry is owned by the n8n delivery track. It must never be read, selected, summarised, or
mutated by the PlatformInit controller:

- `python3 tools/task_controller/taskctl.py` manages the `platform` track only; its `--track` choice is
  restricted to `platform`, and selecting an n8n task ID fails with a non-zero error;
- PlatformInit generated views (`tasks/active/NEXT_TASK.md`, `tasks/active/platform/NEXT_TASK.md`) never
  list n8n work;
- PlatformInit MCP (`get_active_task`, `get_delivery_context`, `get_changed_scope`) serves the platform
  track only and drops `n8n/` and `docs/n8n/` paths from its changed-scope window.

Conversely, no PlatformInit task ID (`P-*`) may be used as a mutable controller dependency of an n8n
task. Shared platform capabilities (CH01 host lifecycle, CH02 hardening) are consumed as external
prerequisites only.

## Registry schema

| Field | Meaning |
|---|---|
| `schemaVersion` | Registry schema revision. |
| `project` | Human-readable track name. |
| `status` | Track-level state; `parked` means the whole track is dormant. |
| `authoritativeRoadmap` | Repository-relative path of the canonical n8n roadmap. |
| `externalPrerequisites` | Stable PlatformInit contracts consumed as external references only, never as mutable controller dependencies. |
| `tasks[]` | Ordered task list. |

Each task entry:

| Field | Meaning |
|---|---|
| `id` | `N8N-CHnn-Tnn` identifier, unique inside this registry. |
| `order` | Monotonic ordering key (`10`, `20`, ...), unique inside this registry. |
| `status` | Task state; only `parked` is valid while the track is parked. |
| `title` | One-line task intent. |
| `dependsOn` | Task IDs inside this registry; every reference must resolve to an existing task. |

The registry deliberately omits the PlatformInit controller fields (`track`, `branch`, `allowedFiles`,
`requiredValidators`, `workflow`). Those belong to `tasks/tracker.json`; adding them here would imply
that the PlatformInit controller can select n8n work.

## Chapter coverage

Every roadmap chapter resolves to at least one registry task:

| Chapter | Tasks |
|---|---|
| N8N-CH01 | `N8N-CH01-T01`, `N8N-CH01-T02` |
| N8N-CH02 | `N8N-CH02-T01`, `N8N-CH02-T02` |
| N8N-CH03 | `N8N-CH03-T01` |
| N8N-CH04 | `N8N-CH04-T01` |
| N8N-CH05 | `N8N-CH05-T01`, `N8N-CH05-T02` |
| N8N-CH06 | `N8N-CH06-T01` |
| N8N-CH07 | `N8N-CH07-T01` |
| N8N-CH08 | `N8N-CH08-T01` |
| N8N-CH09 | `N8N-CH09-T01` |
| N8N-CH10 | `N8N-CH10-T01` |

## Resume rule

Resuming n8n requires an explicit human decision plus a dedicated n8n lifecycle/controller surface.
It must not be done by adding n8n tasks to `tasks/tracker.json`, PlatformInit `/next-task`, or
PlatformInit MCP. Parking is neither deletion nor completion.

## Verification

```bash
# Registry is valid JSON and internally consistent (unique ids/orders, resolved dependencies).
python3 - <<'PY'
import json
d = json.load(open('n8n/tasks/tracker.json'))
ids = {t['id'] for t in d['tasks']}
assert len(ids) == len(d['tasks']), 'duplicate task ids'
assert len({t['order'] for t in d['tasks']}) == len(d['tasks']), 'duplicate order keys'
assert all(set(t['dependsOn']) <= ids for t in d['tasks']), 'unresolved dependency'
assert d['authoritativeRoadmap'] == 'docs/n8n/N8N_ROADMAP.md', 'roadmap pointer drift'
print('n8n registry OK:', len(ids), 'tasks')
PY

# The PlatformInit tracker must not contain n8n work (expected: 0 matches).
grep -c 'N8N-' tasks/tracker.json || true

# The PlatformInit controller must refuse the n8n track (expected: non-zero exit).
python3 tools/task_controller/taskctl.py next --track n8n
```

The n8n registry is intentionally not wired into the PlatformInit controller or its validators;
PlatformInit-only assertions for `tasks/tracker.json` live in that controller's own tests.
