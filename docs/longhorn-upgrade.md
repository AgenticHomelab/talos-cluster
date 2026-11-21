# Longhorn maintenance and upgrade policy

Flux owns the Longhorn HelmRelease in
`kubernetes/infrastructure/longhorn/app/helmrelease.yaml`. Git currently declares
Helm chart `1.13.0`, three replicas by default and **native automatic V1
engine upgrades**, limited by
`concurrentAutomaticEngineUpgradePerNodeLimit: 1`.
These are Git settings, not today's deployed state.

## Nightly changes and ownership

The dedicated GitHub Actions workflow merges eligible Renovate dependency PRs
from **00:00 to 03:59 Europe/Helsinki**, with Longhorn Helm/chart/manager PRs
restricted to **00:00 to 01:59**. Talos Linux and Kubernetes versions remain
outside this policy. The custom Hermes Renovate runner and merger are
retired; Hermes monitors reconciliation, real per-volume engine progress
and assigned incidents, and sends one Finnish Matrix summary at 07:00.
See [Renovate policy](renovate-review-policy.md) and
[automation ownership](automation.md).

A Longhorn Helm chart/manager rollout and live V1 engine upgrade are
**different operations**, potentially ending at different times.
The native per-node concurrency limit constrains engine replacement, not
chart admission, manager rollout, duration or application acceptance.

## Version acceptance

Review the [version-matched upstream upgrade guidance](https://longhorn.io/docs/1.13.0/deploy/upgrade/)
before any proposed hop. A Ready HelmRelease cannot certify that every
attached Volume has adopted the manager's/default EngineImage.

For **every** production volume, verify and record:

- PV/PVC ownership, V1/V2 engine type, frontend, robustness, attachment,
  node locality and active replica count/distribution.
- `Volume.spec.image` (desired), `Volume.status.currentImage`
  (observed), Engine process image and **each** Replica process image.
- Current manager/instance-manager images, installed/default EngineImage,
  native automatic engine limit and any upgrades or retries in flight.
- Application and CNPG health, recent completed individual backups and
  reachable NFS target, and capacity for temporary replica headroom.

Example *read-only* inventory entry points for an approved session:

```bash
kubectl -n longhorn-system get helmrelease longhorn
kubectl -n longhorn-system get volumes.longhorn.io -o wide
kubectl -n longhorn-system get engines.longhorn.io
kubectl -n longhorn-system get replicas.longhorn.io
kubectl -n longhorn-system get engineimages.longhorn.io
kubectl -n longhorn-system get settings.longhorn.io   default-engine-image concurrent-automatic-engine-upgrade-per-node-limit
```

Inspect selected CR specs/statuses via controlled JSON queries, not
unbounded private object dumps. Confirm engine/replica versions across the
**entire** inventory before declaring completion; partial/mixed supported
versions must be recorded explicitly with their exact scope.

## Safety and recovery

- Never assume Longhorn 3-way replication is an application-consistent
  backup. Check actual per-volume backup objects, retention and TrueNAS
  NFS backup target accessibility. Native Longhorn SystemBackup and
  individual volume backups protect different state.
- Check CNPG Barman/WAL health and application-specific recovery material
  for stateful workloads before a potentially migrating upgrade.
- Never downgrade an already-upgraded engine, CRD or database based only
  on a Git/Helm rollback; a supported forward repair and version-specific
  recovery procedure take precedence.
- Do not retry ambiguous native engine actions, force detach, delete
  replica data, bypass PDBs or lower replica guarantees merely to finish
  a scheduled update.
- Stop/notify on an unsupported version hop, failed image preloading,
  degraded volume or missing necessary backup. Preserve old and new
  image evidence for investigation.

The last **dated** full execution report on 2026-10-19 recorded 23/23
V1 volumes and 69 running replicas on Longhorn 1.13.0 following the
approved manager and engine campaigns. This is historical acceptance,
not a live assertion or proof of independent TrueNAS-loss recovery.
The [deployment acceptance](longhorn-1.13.0-deployment-acceptance.md),
[engine execution evidence](longhorn-1.13-engine-upgrade-execution.md)
and [isolated volume-only restore](longhorn-recovery-validation.md)
retain distinct evidence and limitations.

## Routine node drain and incident recovery

Follow [cluster maintenance](maintenance.md) for storage-aware drains,
replica eviction, PDBs and node rejoin. Check the entire volume
inventory before moving replicas. After recovery, verify attachment,
real Engine/Replica process state, applications and scheduled backup
delivery, not merely controller Ready.

Any manual engine upgrade outside the authorized native night policy
requires a separately scoped operator decision, supported upstream
procedure, backups, per-volume preflight and postchecks. No cleanup,
database/data downgrade or storage restart is authorized by this
documentation.
