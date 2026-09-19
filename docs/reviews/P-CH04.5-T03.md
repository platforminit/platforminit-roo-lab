# Review: P-CH04.5-T03 — cycle 2

- **Task:** P-CH04.5-T03 — Stabilize Authentik ingress and TLS contract
- **Reviewer:** `platforminit-openai-reviewer`
- **Review cycle:** 2, fresh child after cycle-1 REQUEST_CHANGES
- **Branch:** `batch/platform-ch04-5-authentik-ingress-tls`
- **Controller entry:** `needs_review`, stage `review`
- **Verdict:** **APPROVE**

## Scope and lifecycle

MCP health succeeded and delivery context confirmed task `P-CH04.5-T03`, status `needs_review`, stage `review`, branch `batch/platform-ch04-5-authentik-ingress-tls`, three changed non-state files, and the required validator `git diff --check`. The changed product scope remains within the three-file budget:

- [`platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh`](../../platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh:1)
- [`platform/identity/docs/ch04-5-authentik-ingress-tls-contract.md`](../../platform/identity/docs/ch04-5-authentik-ingress-tls-contract.md:1)
- [`platform/identity/docs/ch04-5-identity-foundation.md`](../../platform/identity/docs/ch04-5-identity-foundation.md:1)

The working tree also contains controller-owned changes under `tasks/`; those were not edited by this review. No stray product paths or duplicate manifests were found in the repository working tree. The review report itself is the expected reviewer artifact.

## Cycle-1 disposition

### M1 — Medium — duplicate Authentik Ingress host was not enforced

**Resolved.** The validator now bounds its scan to `ROOT_DIR` derived from `BASH_SOURCE`, prunes the declared generated, vendored, secret, VCS, and controller-state directories, sorts manifest paths deterministically, parses YAML documents separated by `---`, and counts host-owning `Ingress` and `Certificate` documents. The canonical-owner anti-vacuity assertion is also present.

Relevant implementation references:

- Scan bounds and prune list: [`ch04-5-validate-authentik-ingress-tls.sh`](../../platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh:35)
- Deterministic manifest enumeration: [`ch04-5-validate-authentik-ingress-tls.sh`](../../platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh:216)
- Multi-document route-owner extraction: [`ch04-5-validate-authentik-ingress-tls.sh`](../../platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh:228)
- Single-owner and anti-vacuity assertions: [`ch04-5-validate-authentik-ingress-tls.sh`](../../platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh:478)
- Aggregated failure and non-zero exit: [`ch04-5-validate-authentik-ingress-tls.sh`](../../platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh:85)

The scan compares the parsed top-level resource `kind`, not arbitrary nested `kind` values such as `issuerRef.kind`; the focused spoof test confirmed that a non-Ingress document containing an `issuerRef` or Authentik host text is not accepted as the canonical route while an actual competing Ingress is detected. Host matching covers the template placeholder, the deploy script's rendered default, and the abstract `auth.<PLATFORM_BASE_DOMAIN>` spelling. Scalar normalization removes quotes, list markers, and surrounding whitespace.

## Consolidated findings

No blocking or non-blocking defects were found in the changed scope.

The one expected warning remains the absence of an explicit Traefik TLS option. The contract explicitly assigns those parameters to the Traefik exposure layer, and the validator reports this as `WARN`, not `FAIL`.

## Acceptance-criteria verdicts

1. **Authentik hostname, Ingress, Certificate, and TLS ownership explicit as one contract: PASS.** The contract defines the hostname, canonical Ingress, Certificate, shared `authentik-tls` secret, namespace, ClusterIssuer authority, single-owner rule, and ingress-shim prohibition. The validator enforces the canonical values and repository-wide single host ownership. See [`ch04-5-authentik-ingress-tls-contract.md`](../../platform/identity/docs/ch04-5-authentik-ingress-tls-contract.md:13) and [`ch04-5-validate-authentik-ingress-tls.sh`](../../platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh:334).
2. **Identity-model bootstrap decoupled from ingress/TLS reconciliation: PASS.** The validator checks that bootstrap has no route/TLS coupling tokens, only read-only Kubernetes invocations, and an identity-model entrypoint; it also checks that the deploy script does not invoke identity-model reconciliation. See [`ch04-5-validate-authentik-ingress-tls.sh`](../../platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh:592) and [`ch04-5-authentik-ingress-tls-contract.md`](../../platform/identity/docs/ch04-5-authentik-ingress-tls-contract.md:54).
3. **Focused repository validation covers the ingress/TLS contract: PASS.** The validator is repository-only, deterministic, repeatable, working-directory independent, aggregates findings, detects the requested negative cases, and exits non-zero when the contract is broken. The identity foundation document also exposes the focused command. See [`ch04-5-identity-foundation.md`](../../platform/identity/docs/ch04-5-identity-foundation.md:194).

The ownership model is unchanged: CH04.5 owns Authentik runtime, the `auth.<PLATFORM_BASE_DOMAIN>` route, and `authentik-*` secrets; CH04.6 owns Argo CD SSO; `ch06-*` identity files remain deprecated compatibility surface. Existing CH05 Checkmk, platform-services Argo CD, and Argo CD application manifests were not misdetected as Authentik route owners.

## Validation evidence

All checks were repository-only; no infrastructure workflow or Authentik, Kubernetes, DNS, Cloudflare, GitHub secret, or GitHub environment mutation was performed.

- `bash platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh` — exit `0`; observed `pass=54 warn=1 fail=0`.
- A second identical validator run — exit `0`; observed `pass=54 warn=1 fail=0`.
- Validator invoked from `/tmp` using its absolute path — exit `0`; observed `pass=54 warn=1 fail=0`.
- `git diff --check` — exit `0`.
- `bash -n platform/identity/validate/ch04-5-validate-authentik-ingress-tls.sh` — exit `0`.

Throwaway negative tests were run only in temporary copies under `/tmp` and were removed afterward:

- Added a second Ingress with the Authentik host: exit `1`; `INGRESS_SINGLE_OWNER` found two owners and the competing owner was reported.
- Added a competitor declaring the host only in `spec.tls[].hosts` with a different secret: exit `1`; both the owner count and TLS-secret mismatch were reported.
- Changed the canonical host to another value: exit `1`; the canonical host assertion failed and `INGRESS_OWNER_CANONICAL` emitted the explicit anti-vacuity message.
- Added a duplicate only under pruned `tasks/active/`: exit `0`; the baseline remained `pass=54 warn=1 fail=0`.
- Added a non-Ingress kind containing nested `issuerRef.kind` and Authentik host text: the scan still detected the actual canonical Ingress plus the test file only when the test file was an actual Ingress; nested kind text was not treated as a route resource.

## Residual risks

- The repository-wide scan intentionally reviews the working tree rather than Git index contents. Untracked manifests are therefore detected, while ignored files and explicitly pruned directories are outside the validator's contract surface by design.
- A third literal base-domain override not represented by the placeholder, deploy-script default, or abstract documentation spelling is not discoverable by this static scan. This is a bounded residual risk and does not block acceptance because the committed rendering contract has those three reviewed host forms.
- The validator proves that the canonical host is present in a Certificate's `dnsNames`, but it does not reject additional unrelated `dnsNames` on that same Certificate. That is not required by the stated single Authentik-host ownership criterion; it remains a small hardening opportunity.
- The validator is not a YAML parser and is intentionally a focused static contract check. Its normalized scalar/document handling passed the requested multi-document, quoting/spacing/list-marker, nested-kind, and negative-route tests; malformed YAML outside the asserted patterns remains a residual static-analysis limitation.
- Live readiness, certificate issuance, DNS propagation, and cluster state remain covered by the existing runtime validator and are outside this repository-only review.

These residual risks do not block the approved verdict.
