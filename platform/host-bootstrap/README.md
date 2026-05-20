# Host bootstrap

`01.1 - Host Bootstrap` is the only workflow expected to connect as `root`.
It creates the `devops` runtime user and the `itadmin` broker user, installs the shared
automation public key for both, installs the scoped privilege helper, and applies the
initial SSH hardening required by later workflows.

## Resulting access model

- `root`: bootstrap only, disabled afterwards
- `devops`: runtime automation user, no standing sudo
- `itadmin`: broker user, scoped sudo only for temporary privilege grants

## Secret model

The current model intentionally uses the existing shared key pair only:

- `AUTOMATION_SSH_PRIVATE_KEY`
- `AUTOMATION_SSH_PUBLIC_KEY`

No parallel admin SSH public key is introduced in this iteration.


## Temporary interactive elevation

Interactive admin access is time-bound. Use workflow `02.6 - Interactive Elevation` with the default 15 minute window. Supported modes:

- `interactive-elevation`: temporary `NOPASSWD:ALL` for the target user
- `automation-admin-shell`: temporary ability for the target user to enter the `itadmin` automation-admin shell
