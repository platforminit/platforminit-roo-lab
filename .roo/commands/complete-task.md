---
description: Close a fully approved PlatformInit task, prepare its PR, and expose the next task
argument-hint: <TASK-ID>
mode: platforminit-release-manager
---

Require controller status `ready_to_close`, OpenAI review `approve`, and OWASP/security `clear`.
Load compact delivery context and changed scope only. Do not rerun broad/full-repo validation just for
reassurance; rely on controller-recorded passing evidence and only execute the controller-owned
completion gate.

Verify branch/task match and allowed-file scope, then run:

`python3 tools/task_controller/taskctl.py complete <TASK-ID> --actor platforminit-release-manager`

Do not edit tracker or generated task views manually. After completion, verify generated views are
current with `taskctl validate`, stage the complete task diff, run `git diff --cached --check`, create
a task-scoped commit, push the task branch, and open/update a feature-to-`dev` PR with a real Markdown
body file (never literal escaped `\\n` text).

The PR body must concisely include Summary, Changed scope, Validation evidence, Review results,
Safety/non-mutated scope, Recovery chain, and Next track state. Do not merge automatically unless the
human explicitly instructs it.

Return the PR URL, closed task ID, and next pending task/track state. Human post-merge work should be
verification-only; task closure belongs on the task branch before merge.
