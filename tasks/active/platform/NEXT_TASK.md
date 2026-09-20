# platform task view

Generated from `tasks/tracker.json`. Do not edit manually.

## P-CH04.5-T05 — Create CH04.5 focused validation and recovery checkpoint

| Field | Value |
|---|---|
| Status | `pending` |
| Track | `platform` |
| Branch | `batch/platform-ch04-5-validation-recovery` |
| Scope | `platform-identity` |
| Dependencies | P-CH04.5-T04B |
| Next actor | `platforminit-orchestrator` |

Consolidate focused CH04.5 semantic, repository and recovery checks so the identity foundation agrees with its current CH04.6 and CH05 consumers before the chapter closes.

### Acceptance criteria

- [ ] focused CH04.5 validation covers repository contract and expected runtime health signals
- [ ] cross-consumer validation proves the CH04.5 desired identity model agrees with active CH04.6 Argo CD and CH05 Checkmk consumers and rejects retired active identities
- [ ] break-glass and recovery prerequisites are documented
- [ ] validation avoids unrelated full-repository checks

### Allowed files

- `platform/identity/**`
- `docs/**`
- `tasks/**`

### Required validators

- `git diff --check`

### Forbidden actions

- do not run infrastructure workflows
- do not mutate Authentik, Kubernetes, DNS, Cloudflare, GitHub secrets, or GitHub environments without explicit human approval
- do not expose secret values

### Controller transition

`python3 tools/task_controller/taskctl.py start P-CH04.5-T05 --actor platforminit-orchestrator`
