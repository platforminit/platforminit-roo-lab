# P-WF-T09 OWASP security/privacy/release review

- **Task:** P-WF-T09 — Enforce terminal specialist stages and fresh-dev startup gate
- **Stage:** security-review
- **Reviewer:** `platforminit-owasp-reviewer`
- **Branch:** `chore/p-wf-t09-workflow`
- **Verdict:** CLEAR

## Scope and review basis

Reviewed only the five controller-reported non-state paths and the directly required lifecycle trust boundary:

- [`.roomodes`](../../.roomodes:1)
- [`05-lifecycle-routing.md`](../../.roo/rules/05-lifecycle-routing.md:1)
- [`pipeline-smoke.md`](../../.roo/commands/pipeline-smoke.md:1)
- [`next-task.md`](../../.roo/commands/next-task.md:1)
- [`validate_pipeline_smoke.py`](../../tools/platforminit_mcp/validate_pipeline_smoke.py:1)

Controller context was obtained from MCP after a successful health check. The controller reported status `needs_security_review`, branch `chore/p-wf-t09-workflow`, five changed non-state files, and the required focused validators. Controller-owned task state and unrelated historical files were not edited or treated as review scope.

## Security and privacy findings

### Controller trust boundary — no finding

The four specialist declarations in [`.roomodes`](../../.roomodes:20) now require a single stage, their own `taskctl` transition, `attempt_completion`, termination, and explicit prohibitions on `new_task`, child spawning, lifecycle `switch_mode`, and next-stage handoff. The orchestrator declaration retains exclusive next-stage routing ownership. The shared [lifecycle-routing rule](../../.roo/rules/05-lifecycle-routing.md:17) repeats the invariant for every specialist and explicitly limits the validator to contract proof.

The validator's checks in [`terminal_mode_errors()`](../../tools/platforminit_mcp/validate_pipeline_smoke.py:222) and [`lifecycle_routing_rule_errors()`](../../tools/platforminit_mcp/validate_pipeline_smoke.py:239) are load-bearing negative controls: removing the `switch_mode` prohibition or shared rule markers causes validation failure. This constrains drift in the shipped contract, while correctly not claiming that text validation authenticates a real Zoo parent/child relationship.

The controller transition remains through `taskctl`; no reviewed path adds direct task-state writes, generated-state editing, evidence forgery, or a competing source of truth. The smoke procedure explicitly marks specialist self-routing, including nested `new_task`, as a runtime failure in [`pipeline-smoke.md`](../../.roo/commands/pipeline-smoke.md:90).

### Startup gate and destructive-operation risk — no finding

The ordered gate in [`next-task.md`](../../.roo/commands/next-task.md:8) requires environment/repository checks, safe status inspection, fetch, and a fast-forward-only `dev` refresh before MCP task resolution. It explicitly forbids `reset --hard`, force-push, rebase, and automatic dirty-work discard. Dirty trees, diverged `dev`, and in-flight dirty feature branches hard-stop with evidence rather than rewriting history. No infrastructure, cloud, Kubernetes, SSH, secret, GitHub-environment, or runtime mutation path is introduced.

The corresponding static checks in [`next_task_startup_gate_errors()`](../../tools/platforminit_mcp/validate_pipeline_smoke.py:264) require the ordering and safety markers. The gate is a documented operator contract rather than an enforcement mechanism against a user who deliberately ignores it; that limitation is appropriate for this task and is not a release blocker.

### Secret, credential, identity, and artifact leakage — no finding

No secret, token, credential, host detail, infrastructure endpoint, identity header, TLS/DNS material, or sensitive evidence content was introduced. The reviewed commands are repository/MCP contract checks and do not dispatch workflows or mutate runtime systems. The handoff remains bounded to the seven documented fields and the static validator rejects payload drift and stale-stage routing.

### Supply chain and privilege escalation — no finding

No installer, dependency, image, privileged command, `sudo`, shell interpolation of workflow input, deletion operation, or permission expansion was added. The changed validator uses local Python file reads and MCP context helpers only.

## Evidence

Independently run for this security review:

```text
python3 tools/platforminit_mcp/validate_pipeline_smoke.py
PASS: gate 1 - 4 specialist stages route to declared fresh-child modes.
PASS: gate 2 - every stage mode boots MCP health + get_delivery_context after a handoff.
PASS: gate 3 - handoff payload bounded to 7 fields and no stale stage is routable.

git diff --check -- .roomodes .roo/rules/05-lifecycle-routing.md .roo/commands/pipeline-smoke.md .roo/commands/next-task.md tools/platforminit_mcp/validate_pipeline_smoke.py
exit 0; no output
```

The prior `validate_mode_access.py --runtime` evidence is reused. Its asserted runtime MCP access and delivery-scope behavior are unchanged by the edited terminal-stage wording and startup-gate contract; rerunning it would be a broad reassurance check rather than an invalidated focused check. The new validator covers the changed `.roomodes` contract markers and the static lifecycle additions.

No infrastructure workflow, runtime mutation, secret access, or GitHub-environment operation was run.

## Residual risks accepted

1. `.roomodes` custom-instruction prohibitions take effect only after the Roo host reloads the custom modes; the manual/runtime smoke layer remains required.
2. Static validation cannot prove Zoo parent/child provenance or observe that the orchestrator actually launched each stage in a fresh child. The procedure explicitly preserves this boundary and treats specialist self-routing as a runtime failure.
3. The five-file scope is at the warning bound for one workflow/agentic-lifecycle subsystem plus the startup command contract; the changed files are tightly coupled and the focused validator passed.

## Verdict

**CLEAR.** The reviewed change strengthens lifecycle isolation and dirty-work safety without adding a controller bypass, secret/privacy exposure, destructive operation, privilege drift, or runtime infrastructure path. Record the verdict through the controller; the orchestrator remains the only owner of the next lifecycle transition.
