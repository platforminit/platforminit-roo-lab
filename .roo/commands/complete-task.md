---
description: Close a fully approved PlatformInit task, prepare its PR, and expose the next task
argument-hint: <TASK-ID>
mode: platforminit-release-manager
---

Require controller status `ready_to_close`, OpenAI review `approve`, and OWASP/security `clear`.
Load compact delivery context and changed scope only. Do not rerun broad/full-repo validation just for
reassurance; rely on controller-recorded passing evidence and only execute the controller-owned
completion gate.

Verify branch/task match and allowed-file scope. Ensure the approved source diff is already committed
on the task branch; do not create an empty duplicate commit if implementation was previously committed.
Then re-read compact MCP/controller state and confirm that the committed source still matches the
approved source fingerprint/evidence.

Run:

`python3 tools/task_controller/taskctl.py complete <TASK-ID> --actor platforminit-release-manager`

Do not edit tracker or generated task views manually. After completion, verify generated views are
current with `taskctl validate`, stage only controller-owned closure metadata plus review/security
evidence, run `git diff --cached --check`, and create a dedicated closure commit. Do not mix new
product/source changes into this commit.

Then push the task branch and open/update a feature-to-`dev` PR with a real Markdown body file (never
literal escaped `\\n` text).

The canonical order is:

`approved source commit -> taskctl complete -> closure/evidence commit -> push -> PR -> human merge`

The PR body must concisely include Summary, Changed scope, Validation evidence, Review results,
Safety/non-mutated scope, Recovery chain, serialization notes when relevant, and Next track state.
Do not merge automatically unless the human explicitly instructs it.

Return the PR URL, closed task ID, source commit, closure commit, and next pending task/track state.
Human post-merge work should be verification-only; task closure belongs on the task branch before merge.
