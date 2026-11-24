# TrueNAS Apps recovery after encrypted dataset unlock

The physical TrueNAS NAS is a separate failure domain. Native NAS application
recovery is not Kubernetes GitOps. The private operations source owns the
[native recovery runbook](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/truenas-app-recovery.md),
helper, allowlist and cron declaration. Its offline CI tests the same helper.
Use the current reviewed private source for an authorized recovery; do not
install a duplicate helper from this repository or infer live cron status from Git.

For declarative Kubernetes desired state, inspect the owning `kubernetes/`
reconciliation unit and its offline validation. Preserve independent recovery
credentials and native snapshots; an offline helper test is not a NAS restore.
