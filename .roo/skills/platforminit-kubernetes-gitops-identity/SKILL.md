---
name: platforminit-kubernetes-gitops-identity
description: Use when working on k3s, Argo CD, Traefik, cert-manager, Cloudflare DNS-01, Authentik, OIDC, or SSO.
---


# PlatformInit Kubernetes, GitOps, and Identity Skill

## Core stack

- k3s single-node
- Traefik ingress
- cert-manager
- Cloudflare DNS-01
- Argo CD
- Authentik

## GitOps boundary

GitHub Actions may bootstrap the platform. Long-running cluster workloads should be owned by Argo CD where practical.

## TLS model

- ClusterIssuer with Cloudflare DNS-01.
- Certificate secret stays in the same namespace as the workload.
- No cross-namespace TLS secret reuse unless explicitly designed.

## Authentik lessons

- Authentik provider reconciliation may require `invalidation_flow=default-provider-invalidation-flow`.
- OIDC client secrets belong in Kubernetes Secrets, not ConfigMaps.
- Break-glass local admin must remain documented.

## Validation

- `kubectl get nodes`
- `kubectl get ingress -A`
- `kubectl get certificates -A`
- `kubectl get applications -n argocd`
- Authentik public route health
- Argo CD SSO login/logout path
