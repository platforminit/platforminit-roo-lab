# sysadminhomelab-ch03

CH03 felelőssége: cert-manager + Cloudflare DNS-01 + Argo CD TLS reproducible baseline.

## Scope
- cert-manager telepítés pinelt verzióval
- Cloudflare API token cluster secret szinkron
- Let's Encrypt staging + prod ClusterIssuer apply
- Argo CD ingress + Certificate manifest
- validate + smoke

## Manual workflows
- `build-ch03-artifact`
- `deploy-ch03-from-artifact`

## Required GitHub secrets
- `SSH_PRIVATE_KEY`
- `TARGET_HOST`
- `TARGET_USER`
- `CF_API_TOKEN`
- `LETSENCRYPT_EMAIL`

## Notes
- A workflow defaultban `staging` issuert használ a biztonságos első issuance-hez.
- Ha a staging smoke sikeres, újrafuttatható `prod` issuerrel is.
