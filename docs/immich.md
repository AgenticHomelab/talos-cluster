# Immich operations and recovery

Immich is a private LAN/Tailnet application at `immich.${BASE_DOMAIN}`. Its
PostgreSQL database, server, machine learning and Valkey are enabled in Flux.
Git is the desired state; application use, backup freshness and recoverability
require separate checks.

## Ownership and deployment

| Owner | Resources |
| --- | --- |
| `kubernetes/applications/immich/ks.yaml` and `app/` | Namespace workload dependencies, 3-instance CNPG `immich-postgres`, ExternalSecrets, ObjectStore, ScheduledBackup, TrueNAS CSI media PVC and NetworkPolicies |
| `config-ks.yaml` and `config/` | OCI chart source, HelmRelease `immich`, ConfigMap values for server, ML and Valkey |
| TrueNAS operator | `tank/k8s/static/immich-media` dataset, NFS export/ACLs, native snapshots, Garage and recovery copies |
| Flux/Omni | Kubernetes desired state / separately managed Talos machine lifecycle |

Both Flux Kustomizations are unsuspended. The official OCI chart is pinned by digest. The 2026-11-17 media cutover
used server and ML v3.4.1 without changing their image pins. Always use
the current manifests as the authoritative chart, image and Helm values source.

The server and ML are singletons using `Recreate`; they can interrupt users
during changes. PostgreSQL 18 has three CNPG instances with required node
anti-affinity, synchronous setting `any 1` and preferred durability.
Each database instance uses a Longhorn PVC (declared 30 GiB), while ML cache
(10 GiB) and Valkey AOF (1 GiB) are separate Longhorn volumes. Replicas are
not backups and PostgreSQL failover does not guarantee zero data loss.

The server mounts `immich/immich-media-truenas`, a RWX TrueNAS CSI claim,
at `/data`. Its declared StorageClass is `truenas-csi-production-retain`;
preserve its `Retain` lifecycle and Flux prune-disabled protection.
The accepted 2026-11-17 mount used NFSv4.1 `sec=sys,hard`, numeric
UID/GID `1000:1000`, and root mode `0750`. The CSI-owned child dataset
is distinct from the retained original `tank/k8s/static/immich-media`
source and its migration-pair snapshot. The requested `2Ti` claim capacity
is not proof of NAS headroom or a usable post-cutover snapshot.
Do not replace `hard` with `soft`, change ACLs recursively, disable
mount checks or delete the original source dataset as PV housekeeping.
TrueNAS/LAN availability is a runtime dependency.

The application uses the non-superuser `immich` SQL role through
`immich-postgres-rw.immich.svc.cluster.local:5432` and
`DB_VECTOR_EXTENSION=vectorchord`. CNPG mounts the immutable pgvector
`0.8.7` and VectorChord `1.1.1` extension images and preloads
`vchord.so`; the SQL extensions are owned by PostgreSQL, not the app.
A new extension image does not update an existing SQL extension. Preserve
PostgreSQL 18 major compatibility and the documented relative
`extension_control_path` / `dynamic_library_path` settings. Never grant
the app database superuser to work around migrations.

Exposure is **internal Traefik `websecure` only**, never `websecure-pub`.
`network-exposure` is `internal`; ingress restricts access to
`immich.${BASE_DOMAIN}`. Namespace ingress NetworkPolicies admit intended
Traefik, CNPG and same-namespace traffic. Outbound network policy is not
deny-by-default; node-side NFS is outside Pod NetworkPolicy. DNS publication
alone is not authorization.

## Credentials and independent custody

The app-local `externalsecret.yaml` synchronizes these existing Secrets from OCI Vault through the shared `oci-vault` ClusterSecretStore:

| Secret | Purpose |
| --- | --- |
| `immich-postgres-user` | Non-superuser database account (basic-auth Secret) |
| `immich-postgres-s3` | Garage `ACCESS_KEY_ID`, `ACCESS_SECRET_KEY`, `AWS_DEFAULT_REGION` |
| `immich-postgres-s3-ca` | Trusted Garage HTTPS CA (shared Vault bundle) |

Recover the independent Flux Git and ESO API signing credentials using the
[bootstrap runbook](bootstrap.md). Retain independently recoverable Garage
bucket/key and CA, database credentials valid for the chosen recovery
point, Omni/etcd recovery dependencies and dataset/snapshot access outside
the cluster/TrueNAS/OCI single failure domain. Do not print or reissue
credentials while investigating a deployment. The Garage bucket is
`immich-postgres-backups` with a dedicated `cnpg-immich` key, not shared
with Matrix or Authentik. TLS validation is mandatory for
`${GARAGE_ENDPOINT_URL}`; never bypass certificate checks.

## Operational checks

Use the approved Omni context and finite timeouts:

```bash
kubectl --request-timeout=15s -n flux-system get kustomizations immich immich-config
kubectl --request-timeout=15s -n immich get helmrelease immich
kubectl --request-timeout=15s -n immich get pods,pvc,ingress
kubectl --request-timeout=15s -n immich get clusters.postgresql.cnpg.io immich-postgres
kubectl --request-timeout=15s -n immich get backups.postgresql.cnpg.io
```

Operator-provided read-only checks on **2026-10-30** showed both Flux
Kustomizations Ready on `main@20e0dcc2`, HelmRelease Ready at chart 0.13.4,
one current server/ML/Valkey Pod each Ready, and three PostgreSQL Pods
`2/2 Running`. One old Failed server Pod belonged to a superseded
ReplicaSet scaled to zero; it was not an active replica or an outage indicator.
The [2026-11-17 accepted media cutover](truenas-csi-legacy-nfs-migration.md#immich-accepted-including-operator-observed-ui-tests)
subsequently verified the CSI mount, a recorded database/source-media
recovery pair and operator-observed login, media readback and fresh upload.
These dated results do not establish current health, an isolated paired
restore, or independent off-NAS recovery. Do not turn retained failed rollout Pods into maintenance
projects when the owning replica set is inactive.

For application acceptance, use a private authorized operator session:
check authentication, original media upload/download integrity, metadata,
thumbnail generation, queued work and ML search without exporting personal
media or credentials. Pod/Helm Ready alone cannot pass this check.

## Backup and recovery contract

**Database:** CNPG Barman Cloud Plugin archives WAL to Garage over verified
TLS and runs `immich-postgres-daily` at **02:30 UTC**. The `30d` policy
declares a database-only retention target; it is not evidence of a usable
30-day recovery chain. Verify fresh completed base backups, continuous WAL,
`ContinuousArchiving`, `LastBackupSucceeded`, target availability and
PostgreSQL/WAL capacity. Do not delete `pg_wal`, disable archiving or assume
daily scheduling succeeded. A completed initial Barman backup was reported
on 2026-10-18; later schedule execution has not been accepted here.

**Media:** Existing TrueNAS native periodic snapshot **task 33** recursively
covers the source under `tank/k8s/static/` and CSI target under
`tank/k8s/csi/`, scheduled at 00:00 Europe/Helsinki with four-week
retention. The 2026-11-17 recorded source snapshot and database restore
point form a retained migration recovery pair. The observed automatic
CSI-target snapshot preceded the payload transfer, so it is not proof of
post-cutover target snapshot coverage. Verify an actual usable target
recovery point before relying on the schedule. Preserve the entire `/data`
tree including originals, thumbnails, video, profiles, internal backup
files and `.immich` markers. Do not create a parallel snapshot schedule.

**Failure domains:** CNPG archives, media snapshots and Longhorn's NFS
backup target all depend on TrueNAS and LAN. Four weeks of media retention
are shorter than the database's 30-day policy. Neither a Longhorn replica
nor an OCI etcd snapshot includes a matching Immich media recovery point.
Off-NAS copies, their independent keys and an isolated paired restore are
**not verified**.

### Capturing a consistent database and media pair

This is a separately authorized maintenance operation, not an unattended
job. Record exact application/chart/PG/extension versions, recovery key
versions and all backups before starting. During an approved maintenance
window, stop **all** writes, uploads and background jobs, including
server-side deletes/transcodes; simply suspending a Flux Kustomization does
not stop existing Pods. Leave CNPG, Garage and NFS available.

1. Take and verify a completed CNPG Barman plugin base backup while writes
   are quiesced. Record the actual Barman backup ID, server, timeline and UTC.
2. Use an approved PostgreSQL admin session to create a unique named
   restore point and switch WAL, recording its LSN, timeline and UTC target T:

   ```sql
   SELECT pg_create_restore_point('immich_pair_UNIQUE_UTC_LABEL');
   SELECT pg_walfile_name(pg_current_wal_lsn());
   SELECT pg_switch_wal();
   ```

   Verify that the entire required WAL chain **through T** is archived and
   retrievable. A WAL switch alone is not confirmation.
3. Without reopening writers, snapshot the **exact** media dataset on
   TrueNAS and record its full dataset@snapshot name, GUID, UTC time,
   numeric owner and ACL contract. Preserve its source snapshot.
4. Independently retain backup, WAL chain, media snapshot/copy and a
   nonsecret pair manifest identifying T, pins, LSN, backup/snapshot IDs
   and custody locations. Retention must cover **both halves**.
5. Reopen writes only after pair verification and a reviewed restoration of
   the normal workload counts and queued jobs.

### Isolated restore and production recovery

A restore exercise must be separately approved. Use an isolated namespace,
separate CNPG Cluster, Longhorn PVCs, separate Valkey/cache, private
networking and a **clone** of the exact media snapshot. Never attach
production PVCs/media read-write, use production ingress, run a production
`zfs rollback` or allow test background jobs to affect real users.

Recover the chosen Barman backup ID through the CNPG plugin ObjectStore
with the matching PostgreSQL major, extension images, preload and
`bootstrap.recovery` plus `recoveryTarget.targetName`. Use the production
archive's **recorded** `serverName: immich-postgres` through an isolated
read-only source ObjectStore; do not copy the production WAL-writing plugin
or create a backup-retention controller with archive delete access.
Restore to T and match it with the cloned media snapshot. An old
physical backup may require the **historic** database password version.
Verify extensions, role privileges and timeline first; then test original
downloads/checksums, representative metadata and a synthetic write only
against the clone. Record RPO/RTO from measured tests, not planned targets.

Production recovery requires an additional approved cutover, isolation,
data-loss decision and rollback plan. A Git revert or image downgrade cannot
undo database migrations or missing media. Do not reuse an Authentik or
Matrix-specific restore runner as an Immich production recovery script.

## Incident and upgrade decisions

| Symptom | Investigate first; do not do this |
| --- | --- |
| NFS blocked, media unavailable | TrueNAS dataset unlock, export, DNS/LAN, hard mount and numeric permissions; never force `soft` or recursive chmod |
| WAL archiving failure | Garage/CA/key, `pg_wal` growth and free space; never delete WAL or waive TLS |
| CNPG or Longhorn degradation | Actual instance/replica/attachment state and capacity; no blind forced detach or engine downgrade |
| SQL extension/migration failure | PG major, vchord/pgvector image-volume and extension SQL compatibility; no superuser workaround |
| Valkey/ML failure | Queue and model cache, not originals; avoid production database/media resets |
| Login/ingress failure | Internal DNS/TLS/Traefik path; never expose the app publicly to bypass a fault |

Review upstream chart/app release notes, image digests, version-supported
migration steps and the current values before upgrades. Server and ML must
stay at matching versions. `HelmRelease.spec.upgrade.remediation.retries: 0`
and `remediateLastFailure: false` prevent automatic rollback of migrated
application data. Preserve a verified pre-upgrade **paired** DB/media recovery
point before a potentially irreversible schema change. After Flux, check
functional behavior and archive delivery, not only Kubernetes readiness.

See [recovery ownership](recovery-ownership-inventory.md),
[Service exposure](service-exposure.md), and
[general cluster maintenance](maintenance.md) for shared boundaries.
