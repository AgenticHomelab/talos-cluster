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

## Valheim world backups and Odin rollback history

Cottage Lake and Brave New World keep three distinct data categories:
Longhorn save PVCs (actual worlds), the Longhorn server installation PVCs,
and separate TrueNAS CSI NAS PVCs for application-level world archives.
The two HelmReleases own their own backup schedules and mount points.

Both servers use Odin's native world-backup feature, with an archive every
**three hours** and `AUTO_BACKUP_DAYS_TO_LIVE=3`,
`AUTO_BACKUP_REMOVE_OLD=1`. Stagger the primary at minute 0 and the
secondary at minute 30 to avoid overlapping NAS writes. This is eight
scheduled archives per server per day, around 24 in a rolling three-day
window, plus backups before updates and on shutdown. Each run prunes
old top-level files in the mounted `/home/steam/backups` directory using
filesystem modification time; it does **not** prune arbitrary nested
directories. Do not store independent/manual long-term recovery copies
on those application backup mounts without separately protecting them
from Odin's native expiry. Validate recent completed archives on both
NAS mounts (gzip integrity and expected world entries) after changes;
these are not tested restores.

The **three-day policy applies only to world archives**, not to the
installation rollback copies. In the pinned Odin 3.8.12 source,
`STAGED_UPDATES=1` promotes new installations and retains timestamped
copies under `/home/steam/valheim/.odin/rollback` without a native
retention configuration. The primary's November 2026 disk-full incident
was caused by ~24.2 GiB of this history and ~3.1 GiB of a separate
legacy installation directory; its world-save PVC used ~0.34 GiB.
Changing the application backup schedule or TTL will not free the
server-installation volume. Keep staged-update validation enabled;
do not add an unreviewed cleanup CronJob or switch off update safety
to solve retention.

For future install-volume capacity incidents, first identify current
and historical installation paths and verify the live game version,
active installation, usable world backups and storage health. If
a one-time cleanup is justified, obtain the operator's explicit
approval for a reviewed **exact-path** removal plan, retain at least
the most recent known-good Odin rollback copy, and avoid touching the
live install, save PVC, NAS backups or retained legacy paths by default.
Verify actual free space and game health after such a separately
authorized action. Keep application archives and Longhorn's global
daily backup/6-hour snapshot retention as different recovery layers.

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
