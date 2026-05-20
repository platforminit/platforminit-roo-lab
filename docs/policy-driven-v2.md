# Policy-driven v2

## Active path
- `platform/host-baseline/policy/baseline.yaml`
- `platform/host-baseline/scripts/apply-policy-baseline.sh`
- `platform/host-baseline/validate/ch01-validate-host.sh`

## Archived path
- `platform/host-baseline/archive/legacy-v1/`

## Workflow naming
- 00 - Build Platform Artifacts
- 01 - Deploy / Recreate Host
- 02 - Apply Host Baseline
- 02.1 - Drift Check
- 02.2 - Temporary Privilege Grant
- 02.3 - OS Security Check
- 02.4 - OS Security Apply
- 02.5 - File Integrity Check
- 03 - Install Kubernetes Cluster
- 04 - Enable Platform (Ingress, TLS, ArgoCD)
