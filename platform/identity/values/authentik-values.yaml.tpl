# CH04.5 Authentik core values.
# Secrets are read from Kubernetes Secrets mounted into server/worker pods.
# This file intentionally contains no real secret values.

authentik:
  secret_key: "file:///authentik-core/secret-key"
  log_level: "info"
  error_reporting:
    enabled: false
  postgresql:
    host: "authentik-postgresql"
    user: "authentik"
    name: "authentik"
    password: "file:///authentik-postgresql-credentials/password"

server:
  replicas: 1
  ingress:
    enabled: false
  metrics:
    enabled: true
    serviceMonitor:
      enabled: false
  envFrom:
    - secretRef:
        name: authentik-bootstrap
  volumes:
    - name: authentik-core
      secret:
        secretName: authentik-core
    - name: authentik-postgresql-credentials
      secret:
        secretName: authentik-postgresql-credentials
  volumeMounts:
    - name: authentik-core
      mountPath: /authentik-core
      readOnly: true
    - name: authentik-postgresql-credentials
      mountPath: /authentik-postgresql-credentials
      readOnly: true
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi

worker:
  replicas: 1
  envFrom:
    - secretRef:
        name: authentik-bootstrap
  volumes:
    - name: authentik-core
      secret:
        secretName: authentik-core
    - name: authentik-postgresql-credentials
      secret:
        secretName: authentik-postgresql-credentials
  volumeMounts:
    - name: authentik-core
      mountPath: /authentik-core
      readOnly: true
    - name: authentik-postgresql-credentials
      mountPath: /authentik-postgresql-credentials
      readOnly: true
  resources:
    requests:
      cpu: 100m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 1Gi

postgresql:
  enabled: true
  auth:
    username: authentik
    database: authentik
    existingSecret: authentik-postgresql-credentials
    secretKeys:
      adminPasswordKey: postgres-password
      userPasswordKey: password
  primary:
    persistence:
      enabled: true
      storageClass: local-path
      size: 8Gi
    resources:
      requests:
        cpu: 100m
        memory: 256Mi
      limits:
        cpu: 750m
        memory: 1Gi
