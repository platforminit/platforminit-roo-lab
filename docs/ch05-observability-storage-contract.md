# CH05 storage contract

CH05 persistent data is reserved under:

```text
/srv/observability/data
```

Current Checkmk implementation:

| Component | Path |
|---|---|
| Checkmk site data | `/srv/observability/data/checkmk` |

Retired paths from the previous Zabbix/OpenObserve/Vector stack should be removed only after backup or explicit confirmation:

```bash
sudo rm -rf /srv/observability/data/zabbix-postgres
sudo rm -rf /srv/observability/data/openobserve
sudo rm -rf /srv/observability/data/vector
```
