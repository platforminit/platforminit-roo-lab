apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  url: https://argocd.__BASE_DOMAIN__
  dex.config: |
    connectors:
      - type: oidc
        id: authentik
        name: Authentik
        config:
          issuer: __AUTHENTIK_OIDC_ISSUER__
          clientID: __ARGOCD_OIDC_CLIENT_ID__
          clientSecret: $dex.authentik.clientSecret
          insecureEnableGroups: true
          getUserInfo: true
          scopes:
            - openid
            - profile
            - email
            - groups
