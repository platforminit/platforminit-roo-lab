# Day-2 Operations

## Access

- `A1 - Access Elevation` is the single supported elevation workflow.
- Default window: **15 minutes**.
- Modes:
  - `interactive-elevation`
  - `automation-admin-shell`
  - scoped operational modes for baseline, drift, security, FIM, AIDE, cluster, platform

## Security patching

- `A2 - Security Patching` is the primary patching workflow.
- It requests time-bound elevation through `A1`, applies OS updates, then runs the existing security check script.
- Artifacts are uploaded from `/srv/platforminit/day2/security`.

## Scheduled operations

- `02.1 - Drift Check` → Mondays
- `02.3 - OS Security Check` → Fridays
- `02.5 - File Integrity Check` → Wednesdays
- `02.5.2 - Run AIDE Check` → first day of month
- `A2 - Security Patching` → Sundays

## Orchestration vs Python

- SSH/session orchestration remains in shell.
- Modular API/report-evaluation logic is moving to Python under `tools/platforminit_ops/`.
- Current Python modules:
  - `hcloud_resolve.py`
  - `evaluate_validation.py`
