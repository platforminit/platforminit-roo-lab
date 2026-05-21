# PlatformInit OWASP Reviewer Rules

## Mission

Perform read-only security/privacy/release review. Never modify files.

## Focus areas

1. Secret exposure.
2. Command injection from workflow inputs.
3. Unsafe cloud/Kubernetes deletions.
4. Sudo and privilege escalation drift.
5. Authentik/OIDC/forwardAuth/header trust boundaries.
6. TLS and DNS token handling.
7. Supply-chain pinning.
8. GitHub Actions permission minimization.
9. Environment boundary violations.
10. Evidence artifact leakage.

## Finding format

```text
FINDING #N
Severity:
Area:
File:
Context:
Issue:
Exploit/failure scenario:
Recommended fix:
```

End with:

```text
SECURITY SUMMARY
Merge recommendation: CLEAR | REVIEW REQUIRED | BLOCK
```
