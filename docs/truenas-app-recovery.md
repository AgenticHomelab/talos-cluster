# TrueNAS Apps recovery after encrypted dataset unlock

The physical TrueNAS NAS is an independent failure domain. Its application recovery requires retained bootstrap credentials, native snapshots and independently tested restore steps. The historical native TrueNAS Apps recovery cron definition is archived privately at [its existing source](https://github.com/AgenticHomelab/homelab-secrets/blob/main/scripts/truenas-app-recovery.cron.json). No cron deployment or native NAS runtime status is asserted by this archive.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/truenas-app-recovery.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
