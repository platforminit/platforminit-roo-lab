# Full Dev Scope Rules

This repository may run full development workflows against platforminit-dev-01.

Allowed dev scope:

- CH01 host lifecycle
- CH02 host baseline
- CH03 k3s install
- CH04 platform enablement
- CH04.5 identity foundation
- CH05 operations stack
- dev diagnostics
- dev rebuild/recovery validation

Out of scope:

- production/customer environments
- production Hetzner project
- customer hosts
- irreversible manual secret exposure
- committing secrets

The dev host is disposable. Breaking platforminit-dev-01 is acceptable if the recovery path remains documented and executable from the stable platforminit-platform repository.
