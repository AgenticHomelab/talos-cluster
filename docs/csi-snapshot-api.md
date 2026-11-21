# Standard Kubernetes CSI snapshot API

Status: **deployed through merged PR #335; read-only acceptance PASS on
2026-10-19 UTC**, main `fc5b5fcac8707a009f64170ae535f4a713a81740`.
[Actual deployment evidence](longhorn-1.13.0-deployment-acceptance.md) records
three Established CRDs, 2/2 controller availability, renewing leadership, resolved
CSI missing-resource errors and 613.383 seconds of stable storage/application
observation. Merged [PR #334](https://github.com/antief/talos-homelab/pull/334)
records manager acceptance and its then-unapproved engine plan. The subsequent
separately approved [engine campaign](longhorn-1.13-engine-upgrade-execution.md)
records the current execution state.
The proposal/validation procedure below remains a reference for the reviewed
implementation; it does not authorize additional cluster operations or snapshots.

## Verified gap and ownership

Read-only inspection on 2026-10-18 UTC, from main
`180076282d4b268694bfd625da7efc884fffd72c`, confirmed:

- No `snapshot.storage.k8s.io` CRDs: VolumeSnapshotClass, VolumeSnapshotContent
  and VolumeSnapshot are absent. Group snapshot CRDs are absent too.
- No common snapshot-controller Deployment, StatefulSet, DaemonSet or standalone
  Pod, and no matching ServiceAccount or upstream RBAC identities exist.
- No registered Flux unit owns a snapshot API/controller. Current Longhorn and
  NFS CSI installations each have their own v8.6.0 **driver-specific snapshotter**;
  these are not duplicate common controllers and must remain untouched.
- The active Longhorn snapshotter reports missing-resource list/watch errors.
  Installing only a driver sidecar cannot supply the common API/controller.

The [upstream architecture](https://github.com/kubernetes-csi/external-snapshotter/blob/78e32cd84e0abec2621924a30e38c755f93e180a/README.md#usage)
uses one common controller Deployment per cluster, with leader election between
replicas, and existing sidecars per CSI driver. The new app owns only the three
standard CRDs, common Deployment, ServiceAccount and RBAC. It does not adopt or
modify Longhorn/NFS Helm resources, existing namespaces, workloads or storage.

## Pinned upstream manifests

[Official v8.6.0 release](https://github.com/kubernetes-csi/external-snapshotter/releases/tag/v8.6.0)
resolves to commit **78e32cd84e0abec2621924a30e38c755f93e180a**. Its minimum Kubernetes
version is 1.25; this cluster runs 1.36.4. The release image is v8.6.0, matching
the deployed Longhorn snapshotter. Source files are vendored **byte-for-byte**:

| Local directory/file under `kubernetes/infrastructure/snapshot-controller/` | Exact upstream path at that commit |
| --- | --- |
| `app/upstream/snapshot.storage.k8s.io_volumesnapshotclasses.yaml` | `client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml` |
| `app/upstream/snapshot.storage.k8s.io_volumesnapshotcontents.yaml` | `client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml` |
| `app/upstream/snapshot.storage.k8s.io_volumesnapshots.yaml` | `client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml` |
| `config/upstream/rbac-snapshot-controller.yaml` | `deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml` |
| `config/upstream/setup-snapshot-controller.yaml` | `deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml` |
| `LICENSE.upstream` | `LICENSE` |

`upstream.sha256` records each original byte hash. Immutable source URLs use
`https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/78e32cd84e0abec2621924a30e38c755f93e180a/`
plus the upstream path. No remote Kustomize base or mutable branch is fetched
during rendering/CI/Flux reconciliation. Do not import the upstream CRD-directory
Kustomization: it includes three additional group snapshot CRDs outside this scope.

The three standard CRDs serve/store v1; retained v1beta1 schemas are not served.
They require no conversion webhook. No VolumeSnapshotClass **instance**, default
class, VolumeSnapshot or VolumeSnapshotContent is created by this proposal.

### Explicit local transformations

The vendored files remain intact; `config/kustomization.yaml` makes these changes:

1. The tagged example still references controller **v8.5.0**. Kustomize replaces
   that image with the released **v8.6.0**, pinned to the official multi-platform
   index digest:
   `registry.k8s.io/sig-storage/snapshot-controller:v8.6.0@sha256:81e79f205083f105e573ba2ebfe5964ede7f69a154e8627f53ebbbccd3ed9f70`.
   Registry manifest bytes and Docker-Content-Digest independently matched this
   SHA-256 during review. The digest fixes the executable selection, not only
   the source YAML/tag.
2. Explicitly keep `--feature-gates=CSIVolumeGroupSnapshot=false`, the
   [tagged default](https://github.com/kubernetes-csi/external-snapshotter/blob/78e32cd84e0abec2621924a30e38c755f93e180a/pkg/features/features.go).
   Group informers/startup checks are conditional on this gate; no group API,
   conversion webhook or distributed-snapshotting support is enabled.
3. Remove the tagged ClusterRole's five unused group-snapshot rules through a
   JSON patch, retaining all eight standard rules. The patch tests the pinned
   rule structure before removing indices 12 through 8. Render validation checks
   the exact permission allowlist, not merely absence of a string in source.
4. Explicit `namespace: kube-system` preserves upstream's namespace and fills
   the lease RoleBinding's omitted ServiceAccount subject namespace. The existing
   system namespace is not declared/adopted/pruned by this app, matching the
   repository's existing pattern for a unit targeting an existing namespace.

Upstream's two replicas, leader election, 35-second minimum Ready period and
rolling-update settings remain unchanged. The example defines no resource
requests, HTTP probe, external Service or privileged host integration. Pod Ready
alone is insufficient for acceptance; verify CRDs, leader lease and clean watches.

## Flux ordering and resource lifecycle

The registry adds `snapshot-controller` as an app-local unit:

```text
apps -> snapshot-controller-crds (app/: three CRDs, wait=true)
       -> snapshot-controller (config/: RBAC + Deployment, dependsOn CRDs)
```

Native Flux/kstatus [CRD health](https://github.com/fluxcd/cli-utils/blob/v1.4.0/pkg/kstatus/status/core.go#L601-L631)
is Current only when Established=True; NamesAccepted=False is failure. The
CRD-only Kustomization checks all three with `wait: true`. Controller `dependsOn`
therefore holds its resources until that unit is Ready. No custom health controller,
CEL logic, wait Job, shell init-container or Longhorn dependency cycle is needed.
Both units retain 10-minute intervals/timeouts and 1-minute retries. The controller
unit has normal pruning; the **CRD unit has prune=false** to retain API definitions
and snapshot metadata on removal. CRD deletion is not routine uninstall/rollback:
it can destroy snapshot metadata and requires a separately reviewed data decision.

Expected rendered footprint: **three CRDs + six common-controller resources**
(Deployment, ServiceAccount, ClusterRole/Binding, lease Role/Binding). Two new Flux
Kustomizations bring the current expected total from 39 to 41; HelmRelease count
stays 28. No Namespace, snapshot class, sidecar, group API, recurring job or data
resource is added. The image and manifests are fixed to this reviewed release;
updates need another reviewed source/digest/permissions check.

## RBAC and material risks

The standard upstream ClusterRole reads PVs and snapshot classes, reads/updates
PVCs, writes events, and manages standard snapshots/contents and their status.
The [upstream controller](https://github.com/kubernetes-csi/external-snapshotter/blob/78e32cd84e0abec2621924a30e38c755f93e180a/pkg/common-controller/snapshot_controller.go)
uses PVC updates for snapshot-source protection/finalizers and snapshot mutations
for binding/lifecycle. Kubernetes RBAC cannot constrain that PVC update permission
to metadata alone. This is a real cluster-wide trusted-controller privilege;
there is no Secret access, wildcard rule, PV write, Node access or group-snapshot
permission. Lease permissions are restricted to the existing kube-system namespace.

Installing a common API makes future snapshot requests possible for CSI drivers
that support them; it does not itself request a snapshot. At first installation
there are no existing standard snapshot objects to reconcile. Future users must
choose a separately reviewed class/driver/deletion policy. Do not infer snapshot
creation, snapshot recovery or independent backup coverage from controller readiness.
Two upstream replicas use leader election but have no placement/request guarantees;
observe actual scheduling and capacity after merge. No automatic rollback, CRD
removal or workload restart is an approved failure response.

Longhorn `csi.allowControllerSecretAccess: false`, TCP/3260 source CIDRs, retention,
HelmRelease, manager/engine images and all production PV/PVC/application resources
are outside this diff. The common controller is distinct from Longhorn's dedicated
CSI service account. Existing Longhorn native backups/SystemBackup remain separate
from Kubernetes CSI snapshot metadata.

## Reproducible pre-merge validation

From the repository root, using the existing tools and test runner:

```bash
(cd kubernetes/infrastructure/snapshot-controller && sha256sum --check upstream.sha256)
bash scripts/tests/csi-snapshot-controller-test.sh
./scripts/validate-reconciliation-unit-registry.sh
flux build kustomization snapshot-controller-crds \
  --path ./kubernetes/infrastructure/snapshot-controller/app \
  --kustomization-file ./kubernetes/infrastructure/snapshot-controller/ks.yaml --dry-run
flux build kustomization snapshot-controller \
  --path ./kubernetes/infrastructure/snapshot-controller/config \
  --kustomization-file ./kubernetes/infrastructure/snapshot-controller/config-ks.yaml --dry-run
HELM_CHARTS_DIR=/path/to/exact/charts ./scripts/validate-complete-desired-state.sh
git diff --check
```

The existing shell-test gate automatically runs the new offline provenance,
resource-allowlist, RBAC, image/group-feature and dependency contract. No new test
framework or permanent maintenance runtime is introduced. Compare the exact
rendered identities with live objects/Flux inventory before approval to avoid
adoption/duplicate ownership. Re-fetch the six source files from the immutable
commit and compare their SHA-256 values for independent provenance review.

Require current-main integration and exact-head CI on the final PR. **Stop for
operator merge approval.** No imperative apply, Helm upgrade or forced Flux
reconciliation belongs to this repair.

## Acceptance after separately approved merge

Allow normal Flux reconciliation. Observe source/applied revision and both new
Kustomizations; use their existing ten-minute rollout deadlines once reconciliation
starts. Require all three CRDs Established with v1 served/storage before the common
controller rolls out. Require one common Deployment only, its two upstream replicas
available after the 35-second period, and a renewing leader lease. Verify its logs
and Longhorn's active CSI snapshotter have stopped reporting missing-resource
list/watch errors after informer retries. Check NFS's existing sidecar too without
changing it. No snapshots are to be created merely to test this.

Repeat the full live volume inventory, all original Volume/PV/PVC identities and
bindings, actual desired/current/engine/replica images (expected 23 volumes on
1.12.1, 23 running engines and 69 healthy RW replicas, three distinct nodes each),
no rebuild/restore/migration, pressure-free nodes, 41 Kustomizations/28 HelmReleases,
Longhorn manager/Global Manager/CSI/IM/EI health, retained Ready SystemBackup and
reachable target. Automatic engine upgrades must remain 0. Investigate any new
volume instead of silently enforcing stale counts.

Verify representative Vaultwarden, Authentik, Matrix, Immich, Calibre, Valheim and
Mumble endpoints/protocols and original Pod UIDs/restarts. All CNPG clusters need
3/3 readiness, expected primary identities, two streaming standbys, successful
recent native backups and working WAL archiving. Idle WAL alone is not an archive
failure. No Secret, vault, game world or private application content inspection.

Require a fresh **at least ten-minute stable storage/application observation**.
Record timestamps/samples and any protocol loss separately from demonstrated
application failure. A transient Flux Ready transition during normal reconciliation
must trigger fresh generation/Ready/Healthy conditions and event checks: distinguish
it from persistent failure, do not certify health from a stale successful revision,
and do not force a reconcile/restart. Extend/restart a bounded observation if
needed; stop on actual storage/CSI/app failure or an unresolved timeout. Fresh
attachment behavior remains unexercised unless it occurs naturally; never detach
or restart a workload to manufacture it.

After actual acceptance, update draft #334 with factual results, warning resolution,
observation duration and engine-phase GO/NO-GO. If blocked, preserve working state,
collect sanitized diagnostics and report the exact failure; no downgrade, force
detach, replica deletion, manager/workload restart or broad rollback. Do not merge
#334 or execute the 23 engine upgrades. A green repair PR is not deployment evidence.
