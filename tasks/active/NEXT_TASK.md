# Next Active Batch: B00 - Full Dev Roo Lab Bootstrap

## Human entrypoint

Open the repository from Ubuntu WSL:

```bash
cd /mnt/d/SYSADMIN/platforminit-roo-lab
code .
```

Then give Roo this prompt:

```text
Read tasks/active/NEXT_TASK.md and execute the active batch exactly as described.
```

## Mandatory environment

Roo must run from VS Code Remote WSL.

Required checks:

```bash
pwd
grep -Eiq "microsoft|wsl" /proc/version && echo WSL_OK
id -un
git branch --show-current
git status --short
```

Expected:

```text
/mnt/d/SYSADMIN/platforminit-roo-lab
WSL_OK
hattila
chore/bootstrap-full-dev-roo-lab
```

## Repository role

This repository is a full-access dev workflow rehearsal repository.

It may modify or break:

- platforminit-dev-01
- development-only PlatformInit workflows
- development Kubernetes resources
- development Checkmk/operations stack

It must not target:

- production/customer environments
- customer hosts
- production Hetzner project
- production DNS zones outside the approved dev scope

## Batch tasks

B00-T01 - Verify repository snapshot structure
B00-T02 - Add Roo environment rules
B00-T03 - Add Git safety rules
B00-T04 - Add full-dev scope rules
B00-T05 - Add review-flow rules
B00-T06 - Add README warning and operating model docs
B00-T07 - Add WSL runtime guard script
B00-T08 - Document GitHub Environment: roo-lab-dev
B00-T09 - Document recovery chain from CH01 to CH05
B00-T10 - Prepare review handoff and commit

## Completion criteria

- The repo clearly states it is a full-access dev rehearsal repo.
- Roo knows this repo may break platforminit-dev-01.
- Production/customer scope is explicitly excluded.
- WSL-only execution is documented.
- Branch and git safety rules are documented.
- Recovery chain is documented.
- No secrets are committed.
