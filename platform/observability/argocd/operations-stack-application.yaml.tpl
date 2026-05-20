apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: operations-stack
  namespace: argocd
  labels:
    app.kubernetes.io/name: operations-stack
    app.kubernetes.io/part-of: platforminit
    platforminit.io/chapter: ch05
    platforminit.io/gitops-mode: owner
  annotations:
    platforminit.io/description: "Argo CD-owned PlatformInit operations stack: Checkmk Community with Authentik trusted-header SSO."
spec:
  project: operations
  source:
    repoURL: __REPO_URL__
    targetRevision: "__TARGET_REVISION__"
    path: platform/observability/manifests
    helm:
      releaseName: platforminit-operations
      parameters:
        - name: baseDomain
          value: __BASE_DOMAIN__
        - name: tlsIssuer
          value: __TLS_ISSUER__
  destination:
    server: https://kubernetes.default.svc
    namespace: operations
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
      - PruneLast=true
