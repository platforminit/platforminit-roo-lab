# k3s Data Directory Storage Contract

PlatformInit expects k3s data under:

```text
/srv/data/k3s
```

This matters because the k3s local-path provisioner stores PVC backing data below the k3s data directory. If k3s falls back to `/var/lib/rancher/k3s` or `/srv/k3s`, observability/database PVCs can grow on the wrong partition.

## Audit commands

```bash
sudo grep -R "^data-dir:" /etc/rancher/k3s/config.yaml
sudo systemctl cat k3s | sed -n '/ExecStart/,+5p'
sudo du -xh /srv/data/k3s | sort -hr | head -50
sudo du -xh /srv/k3s 2>/dev/null | sort -hr | head -50 || true
sudo du -xh /var/lib/rancher/k3s 2>/dev/null | sort -hr | head -50 || true
```

## Expected config

```yaml
data-dir: /srv/data/k3s
```

## Remediation

If the running host still uses `/srv/k3s` or `/var/lib/rancher/k3s`, treat it as stale CH03 state. Re-run the corrected CH03 install path after preserving any data that must survive.
