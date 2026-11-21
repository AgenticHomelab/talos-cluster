# Talos cluster maintenance

The Talos control plane is operated through Omni. Never replace the Omni API
access path with a single-node endpoint during normal maintenance. Before
any node drain or version change, verify the current Kubernetes control plane,
quorum, Longhorn volumes and replicas, CloudNativePG, ingress, Flux and native
backup/recovery prerequisites.

The exact node addressing, machine-specific labels, authorized drain/shutdown,
restart, upgrade, version-change and rollback procedures are maintained in the
[private maintenance runbook](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/maintenance.md).

A Talos template commit is **not** an Omni sync. An Omni sync or machine
operation requires an approved plan, current template diff and separate
runtime verification. Changes to persistent Kubernetes state belong in Flux;
machine lifecycle belongs to Omni. A Git revert alone cannot undo every
version or storage migration.
