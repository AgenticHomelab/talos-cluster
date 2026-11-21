# Talos etcd backup and recovery boundary

Omni, not Flux, owns Talos machine configuration and encrypted cluster etcd
snapshots. This Kubernetes GitOps source does not contain the machine-specific
backup destination, encryption identity, machine UUID mapping or restore
credentials. The hourly interval is declared in the private Omni template.

The [private etcd backup and recovery runbook](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/etcd-backups.md)
contains the current target, monitoring commands, recovery prerequisites and
dated verification evidence. Preserve an independent Omni application backup,
Omni's cluster encryption material and externally recoverable credentials.

**Do not infer successful isolated Talos/Kubernetes recovery from encrypted
snapshot existence or a healthy Omni backup status.** PVCs, CNPG and native
application data require their separate recovery mechanisms. TrueNAS-backed
copies share its failure domain unless an independently verified offsite copy
exists. Any template sync or restore is a separately authorized mutation.
