# Longhorn 1.12.1 recovery and engine-operation research

Researched 2026-10-18 against versioned upstream documentation and manager source tagged `v1.12.1`. This note establishes supported procedures; it contains no live execution or acceptance evidence.

## Isolated restore

The 1.12.1 restore documentation expressly supports creating a new `longhorn.io/v1beta2` `Volume` with `spec.fromBackup` equal to the selected Backup's exact `status.url`, `spec.size` equal to its exact quoted decimal `status.volumeSize`, `frontend: blockdev`, `dataEngine: v1`, and three replicas. Use a unique test name. The documentation requires completion before workload attachment: `status.state: detached` and `status.restoreRequired: false`. A static PV must use the new test volume name as `spec.csi.volumeHandle`; a PVC explicitly selects that test PV. These are separate resources from the production volume. [Restore from a Backup](https://longhorn.io/docs/1.12.1/snapshots-and-backups/backup-and-restore/restore-from-a-backup/)

Disable backup recurring-job inheritance with `spec.restoreVolumeRecurringJob: disabled`; `ignored` inherits the cluster setting and `enabled` forces restoration. This per-volume override avoids changing production settings. [Restore Volume Recurring Jobs](https://longhorn.io/docs/1.12.1/snapshots-and-backups/backup-and-restore/restore-recurring-jobs-from-a-backup/)

**Additional isolation requirement from tagged source:** the controller calls `FixupRecurringJob`, which assigns the default recurring-job group when no recurring-job/group labels exist. Set the test Volume label `recurring-job-group.longhorn.io/default: disabled` explicitly, and do not supply any enabled recurring selectors. The presence of that disabled label prevents automatic default assignment, while jobs select only labels equal to `enabled`. Verify the resulting live labels. Keep the temporary PVC free of the recurring-job source label and production labels. This is a source-derived precaution, distinct from disabling backup inheritance. [Datastore default label logic](https://github.com/longhorn/longhorn-manager/blob/v1.12.1/datastore/longhorn.go#L4342-L4385), [job selection](https://github.com/longhorn/longhorn-manager/blob/v1.12.1/app/recurringjob/util.go#L113-L126), [controller](https://github.com/longhorn/longhorn-manager/blob/v1.12.1/controller/volume_controller.go#L5849-L5950)

Use a static test PV with `persistentVolumeReclaimPolicy: Retain`, explicit test claim binding, the source filesystem type, and read-only CSI/mount declarations. For ext4, `ro,noload` additionally prevents journal replay. Require an already populated filesystem; avoid formatting an empty block device. A dedicated namespace, default-deny ingress/egress NetworkPolicy, no service account token, and bounded non-sensitive structural checks isolate inspection. These are task-specific Kubernetes precautions; they are not evidence of application consistency or independent disaster recovery.

## Cleanup and backup protection

Deleting a PVC can cascade to the Longhorn volume when its PV reclaim policy is `Delete`. Longhorn deletion can also remove the PV/PVC it considers associated with that volume. Therefore use `Retain`, stop/delete the verification Pod first, wait for detachment, confirm test-only PV/PVC/volume ownership, remove the test PVC/PV, then remove only the exact test Volume, and finally remove its namespace. Inspect disappearance of owned engines/replicas and preserve existing backup resources. [Deletion documentation](https://longhorn.io/docs/1.12.1/nodes-and-volumes/volumes/delete-volumes/)

The tagged Volume controller deletion path removes volume-owned snapshots, engines, replicas, its recorded PV/PVC and Longhorn attachment, then removes the Volume finalizer. It does not invoke Backup or BackupVolume deletion in this path. Backup deletion has distinct API routes. This supports explicit deletion of the isolated test Volume after binding cleanup; it does not authorize deleting source BackupVolumes or backups. Verify backup identities remain after cleanup. [Volume deletion controller](https://github.com/longhorn/longhorn-manager/blob/v1.12.1/controller/volume_controller.go#L388-L545), [separate backup routes](https://github.com/longhorn/longhorn-manager/blob/v1.12.1/api/router.go#L144-L160)

## Native V1 engine upgrade

Version 1.12.1 documentation explicitly supports healthy V1 live upgrades from 1.11.x to 1.12.1. It requires manager upgrade first and backups. The iSCSI frontend cannot live-upgrade. The UI operation is select one volume, **Upgrade Engine**, select target image, confirm. Temporary replica count doubles before returning to the original count. Treat this as extra process and resource demand; do not infer a full additional physical copy without observed evidence. [Manual engine upgrade](https://longhorn.io/docs/1.12.1/deploy/upgrade/upgrade-engine/)

The native manager API equivalent is:

```http
POST /v1/volumes/<exact-volume-name>?action=engineUpgrade
Content-Type: application/json

{"image":"docker.io/longhornio/longhorn-engine:v1.12.1"}
```

The tagged router registers this POST action; `EngineUpgradeInput` has JSON field `image`, and the API invokes `VolumeManager.EngineUpgrade`. [Router](https://github.com/longhorn/longhorn-manager/blob/v1.12.1/api/router.go#L104-L132), [input](https://github.com/longhorn/longhorn-manager/blob/v1.12.1/api/model.go#L351-L353), [handler](https://github.com/longhorn/longhorn-manager/blob/v1.12.1/api/volume.go#L820-L841)

The manager validates V1, conflicting upgrade state, both old/target image readiness on replica and attachment nodes, migration, attached-volume health, and strict-local restrictions, then updates `spec.image`. An arbitrary Kubernetes patch bypasses these API checks and must not substitute for this native action. The source contains an in-progress rollback branch, but this establishes neither a safe completed-engine downgrade nor authorization for automatic rollback. Stop and preserve evidence on failure; further recovery requires operator approval. [Manager implementation](https://github.com/longhorn/longhorn-manager/blob/v1.12.1/manager/volume.go#L844-L943)

## Recovery limits

A SystemBackup contains Longhorn-operated resource metadata, including PV/PVCs and settings, and can coordinate volume backups according to policy. It excludes ordinary application Pods and Longhorn Node objects. A successful isolated volume restore cannot replace this metadata coverage, restore the entire cluster, establish application consistency, or demonstrate independent offsite recovery of a TrueNAS-dependent backup target. [System backup contents and policy](https://longhorn.io/docs/1.12.1/advanced-resources/system-backup-restore/backup-longhorn-system/)
