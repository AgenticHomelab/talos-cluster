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

## Valheim install-volume capacity

The primary Valheim server keeps its installation, worlds and application
backups on separate claims. Its `persistence.server.size` is declared in
[`helmrelease.yaml`](../kubernetes/applications/valheim/app/helmrelease.yaml).
Check the mounted filesystem's free blocks and inodes, including hidden
`.odin/rollback` and legacy install directories, before changing capacity.
Staged updates can retain old installation copies; increasing the PVC does
not introduce a retention limit for them. Track subsequent growth and review
any proposed cleanup separately rather than adding automatic deletion.

Use a reviewed GitOps storage-request increase with Longhorn's supported PVC
expansion path. Preserve the claim identity, world and backup mounts, and
replica protection. Verify the existing backups and per-replica-node capacity
first. After delivery, verify both PVC/PV capacity and actual filesystem free
space, game-server operation and the unaffected second server. Expansion
cannot be undone by shrinking the PVC or reverting its size in Helm; a
Helm rollback is not a data rollback. Do not edit PV capacity directly.
