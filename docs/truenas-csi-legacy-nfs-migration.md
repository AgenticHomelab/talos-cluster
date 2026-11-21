# Legacy NFS CSI workload migration and retirement

Historical TrueNAS CSI and NFS migration evidence. Current workload PVCs and datasets remain owned by their native controllers; this record is not authorization for storage mutation.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/truenas-csi-legacy-nfs-migration.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
