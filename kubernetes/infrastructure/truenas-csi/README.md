# TrueNAS CSI storage

This Flux unit installs the official TrueNAS CSI driver (`csi.truenas.io`).
It provisions NFSv4.1 RWX datasets and exports for the active BorgWarehouse,
Calibre Web Automated, Immich and Valheim storage claims. The CSI driver
owns its child datasets and NFS exports; Flux owns the HelmRelease,
StorageClasses and PVCs. The legacy `nfs.csi.k8s.io` controller and its StorageClass were retired
in PR #449 after verifying no old-driver PV or workload consumers and
confirming the normal Helm uninstall. TrueNAS NFS itself remains required,
and Longhorn remains the replicated block layer.

The API key is stored in the SOPS-encrypted `truenas-csi-api.sops.yaml` Secret
and is never committed in plaintext. This is the current cluster-side
credential delivery mechanism, **not** proof that the corresponding key
has already been adopted as an OCI Vault secret. The agreed target is
OCI Vault as authority for stable TrueNAS API-key values, with SOPS retaining
the protected Kubernetes consumer copy. Do not rotate credentials as part
of legacy-driver retirement.

TLS verification remains enabled with the normal public CA trust store;
the verified ACME certificate needs no private CA ConfigMap or insecure TLS.

The selected TrueNAS infrastructure OpenTofu repository
[`antief/truenas-infra`](https://github.com/antief/truenas-infra) may manage
stable parent datasets and the TrueNAS-side identity/privilege definitions
after verified import. **Do not import CSI-created child datasets, their
NFS shares or CSI-owned lifecycle resources into OpenTofu.** Stable static
NAS exports and recovery snapshots have separate ownership and disposal
decisions. Removing a Kubernetes PV or the old CSI driver does not authorize
deleting their original TrueNAS datasets or recovery material.

The TrueNAS CSI API privilege is method-scoped, not dataset-scoped.
In particular, `DATASET_DELETE` can recursively delete datasets outside
a disposable pilot tree; never use a production claim as an ad hoc test.

| StorageClass | Reclaim | Dataset path |
| --- | --- | --- |
| `truenas-csi-pilot-delete` | `Delete` | `k8s/csi-pilot/delete` |
| `truenas-csi-pilot-retain` | `Retain` | `k8s/csi-pilot/retain` |
| `truenas-csi-production-retain` | `Retain` | `k8s/csi` |

## Acceptance and recovery boundaries

The production cutovers and dated source/target recovery evidence are
recorded in [the legacy migration runbook](../../../docs/truenas-csi-legacy-nfs-migration.md).
Before driver cleanup or any storage change, confirm actual CSI controller
and node plugin health, all production PV/PVC bindings, running workload
mounts and current NAS protection. A Ready HelmRelease or `Retain` policy
is not a verified restore or independent off-NAS backup.

Disposable pilot acceptance, if repeated under separate authorization,
uses isolated PVCs and checks TLS-validated API access, multi-node RWX,
numeric ownership, quota/expansion, Delete lifecycle and Retain reattachment.
Never perform a disposable-lifecycle test against production children.
Do not change NAS-wide NFS service, production exports, source datasets
or snapshots while retiring the old `nfs-csi` controller.
