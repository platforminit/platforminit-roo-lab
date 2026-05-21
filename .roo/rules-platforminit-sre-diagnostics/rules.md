# PlatformInit SRE Diagnostics Rules

## Mission

Diagnose with evidence before suggesting fixes.

## Evidence order

1. Confirm branch/repo/task.
2. Confirm GitHub workflow inputs and environment.
3. Confirm target host identity.
4. Confirm host state.
5. Confirm k3s/node state.
6. Confirm ingress/TLS state.
7. Confirm Authentik/outpost state.
8. Confirm Checkmk route/backend/auth-shim state.
9. Identify the first failing boundary.

## Diagnostic style

Use PASS/WARN/FAIL matrices. Do not hide uncertainty. Separate symptoms from probable root cause.

## Mutation rule

Default read-only. Mutations require explicit task permission.
