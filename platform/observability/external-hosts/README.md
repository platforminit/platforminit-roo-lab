# CH05 External Host Monitoring

External host onboarding is intentionally deferred until the Checkmk Community core layer is validated.

Initial scope:

```text
platforminit-dev-01
Checkmk Community UI
Authentik trusted-header SSO wrapper
single persistent data path: /srv/observability/data/checkmk
```

Next scope:

```text
install/register Checkmk agent on platforminit-dev-01
add host/service discovery
add HTTP/TCP checks for Kubernetes, Argo CD, Authentik and Checkmk itself
```
