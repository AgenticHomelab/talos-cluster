# Platform and security update review plans

These are deployment review gates and dated upgrade records. A merged version
pin does not authorize an Omni sync. No platform version, runtime job or
production resource is changed by this document.
Evidence is dated 2026-10-12 except explicitly dated later observations;
re-read exact PR heads and current metadata before
approval. Missing preflight evidence remains NOT VERIFIED.

## Flux compatibility

At the recorded 2026-10-12 acceptance, the approved Flux deployment queue had
completed. Flux 2.9.6 and Flux Operator 0.61.0 were reconciled; the existing
Operator Helm release was adopted into GitOps. The standalone server-only Web
release was also 0.61.0. Kubernetes was 1.36.4, within Flux 2.9's documented
1.34–1.36 range. These are dated runtime observations, not current live
state. The earlier Flux 2.8 / bootstrap
Operator 0.48.0 compatibility and ownership-transfer work is complete, not a
pending upgrade proposal. Sources:
[Flux 2.9 release](https://github.com/fluxcd/flux2/releases/tag/v2.9.0),
[Flux 2.9.6](https://github.com/fluxcd/flux2/releases/tag/v2.9.6),
[Flux upgrade guidance](https://fluxcd.io/flux/installation/upgrade/).

Future changes still require live CRD served/storage and resource inventories,
removed-API checks, rendered ownership/pruning comparison, ExternalSecret delivery and dependency
validation, exact-head CI and current-base integration evidence. After an approved
merge, verify normal reconciliation, controller health, source revisions and all
child Kustomizations/HelmReleases. A Git revert is not a proven CRD downgrade.

Kubernetes 1.37 deployment remains BLOCKED by the recorded compatibility gate:
Flux 2.9 documented support only through 1.36 at this review. PR #209 merged
on 2026-10-30 and current Git pins Kubernetes 1.37.2. The merge does not prove
Flux/CNI/CSI compatibility or a deployed version change. Preserve the
compatibility preflight and complete Omni template diff before any approved sync.

## Vaultwarden 1.37.4: completed

On 2026-10-12, PR #267 was squash-merged as
`fcd91c1e2aceb18555bd7f404e0a87ed0d79c489`. The cluster reconciled
Vaultwarden `1.37.4-alpine`; the existing Longhorn PVC, Recreate rollout,
`RemediateOnFailure` strategy, zero upgrade-remediation retries and
`remediateLastFailure: false` were preserved. Readiness, HTTPS `/alive`,
certificate verification and storage health passed in the private execution
report. The observed endpoint interruption was approximately 35 seconds.

Before the upgrade, an AGE-encrypted, application-consistent production capture
was independently restored in a private isolated test. SQLite integrity, file
and signing-key preservation, and old-image startup passed. This evidence
establishes a tested recovery point, not complete disaster recovery: independent
offsite custody and recovery-key escrow remain NOT VERIFIED. Retain the approved
encrypted artifact for at least 30 days and until the recovery decision closes.

The successful 1.37.4 startup is evidence that its fail-closed SQLite migration
path completed, but an independent SQL schema query was NOT VERIFIED.
Authenticated login, 2FA, client sync and attachment/Send workflows were NOT
VERIFIED by the agent. An authorized operator may check these with normal
clients, without supplying vault credentials to automation. No automatic
database downgrade or image rollback is approved. See
[`vaultwarden-recovery.md`](vaultwarden-recovery.md) for recovery boundaries.

## Shared app-template 5.3.0: completed

PR #276 was squash-merged as
`7e2f51ca4d9668b2ea0ee104c6db83c491b3ea22` and its documentation
follow-up PR #288 as
`67ccdd7bab833b6c73fa7fddf523be42cfb643f1`.
The pinned `bjw-s app-template` OCI source is 5.3.0; the reviewed live
post-merge inventory confirmed all 12 referring HelmReleases Ready, alongside
32/32 Flux Kustomizations, 3/3 nodes and 20/20 PVCs. This is **completed
deployment evidence**, not an open upgrade candidate or proof of perpetual
health. See [app-template upgrade history](app-template-upgrade.md) for the
verified digest, consumers and future review method.

## Longhorn

The original [eight-volume 1.11.x → 1.12.1 sequence](longhorn-engine-upgrade-plan.md)
passed under separately approved native operations; merged PR #329 preserves its
historical evidence. The subsequent [complete inventory/alignment](longhorn-engine-alignment-20261018.md)
includes 23 production volumes and all five remaining 1.12.0 engines, plus the
new Immich volumes. Use its timestamped actual results and backup coverage rather
than inferring storage state from the manager/chart version.

[PR #274](https://github.com/antief/talos-homelab/pull/274) was operator-merged as
`180076282d4b268694bfd625da7efc884fffd72c`; normal Flux deployed chart/manager
1.13.0. [Deployment acceptance](longhorn-1.13.0-deployment-acceptance.md) **PASS**
on 2026-10-19 after merged #335 supplied the standard CSI snapshot API/controller.
At manager acceptance, all 23 volumes/engines and 69 replicas remained on 1.12.1. The
613.383-second fresh observation passed with 41 Kustomizations/28 HelmReleases
Ready, manager/Global Manager/CSI healthy, clean fresh snapshotter watches,
healthy applications and three 3/3 CNPG clusters. CSI Secret restriction and
verified TCP/3260 source filtering remain effective. Fresh attachment behavior
and snapshot creation/restore remain unexercised.
The separately approved [engine campaign](longhorn-1.13-engine-upgrade-execution.md)
has **23/23 per-volume PASS** with 23 engines and 69 replicas on 1.13.0; final
ten-minute campaign observation passed (600.002s, 11 samples). The original per-volume inventory remains in the
[private operational record](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/longhorn-1.13-engine-upgrade-plan.md).
Completed operations must not be repeated; this documentation grants no new scope.

Git now enables native automatic V1 engine upgrades at one per node after
eligible manager updates, as approved in PR #344. This is configured behavior,
not evidence of the current running engine versions.

Supported engine-only changes use
healthy storage, current completed Longhorn backups, native image compatibility,
capacity and application checks; no fresh application-consistent capture or
isolated restore is mandatory for that accepted scope. Preserve stricter recovery
requirements for future application/database upgrades and actual restores.
The existing AIOStreams volume-only restore passed inside the production cluster;
it does not establish application consistency, SystemBackup restoration or
independent offsite DR. Historical backups/BackupVolumes remain protected.

## Talos and Kubernetes

PR #210 and PR #209 merged on 2026-10-30. Current Git pins Talos v1.14.5
and Kubernetes v1.37.2 in the [private Omni template](https://github.com/AgenticHomelab/homelab-secrets/blob/main/talos/cluster-template.yaml.in). These are desired
versions, not proof of an Omni sync, a deployed upgrade or upgrade readiness.

The [Talos 1.14 support matrix](https://docs.siderolabs.com/talos/v1.14/getting-started/support-matrix)
requires Omni >=1.10.0 and supports Kubernetes 1.37; Talos 1.13 does not list
1.37. The observed OCI Omni image is 1.12.3, but complete upgrade prerequisites
are not thereby established.

Review [Talos upgrade guidance](https://docs.siderolabs.com/talos/v1.14/configure-your-talos-cluster/lifecycle-management/upgrading-talos)
and [1.14.4 notes](https://github.com/siderolabs/talos/releases/tag/v1.14.4):
Image Factory installer/schematic/extension handling and multipath configuration
migration may apply. Confirm machine configuration drift, exact schematic,
extensions, etcd backup/recovery, quorum, PDBs and storage health.

The earlier preflight reported an available target installer and iscsi-tools
extension, zero Omni template drift and three healthy etcd voters. Those checks
were not repeated for the current Git pins. The OCI repository still pins
`talosctl` v1.13.5; the etcd minor transition and restore contract remain
NOT VERIFIED. The Git merges did not establish production rollout approval.
Plan future **Talos OS** upgrades one node at a time while retaining a
reviewed Kubernetes minor. PR #275, which proposed a Kubernetes 1.36.5 patch,
was closed without merge. Flux 2.9.6 compatibility with that earlier minor
was established in the recorded review.

On 2026-10-12, Omni S3 etcd backups were activated, two automatic encrypted
snapshots were independently retrieved, and post-activation Omni encryption
state was preserved in an independent encrypted application archive. A full
isolated restore and observed 30-day expiration remain NOT VERIFIED, but the
operator explicitly accepted the isolated-restore uncertainty as a residual
risk for **routine homelab patch upgrades**. Do not turn that accepted risk
into a permanent patch-upgrade blocker; reassess separately for destructive
storage, trust, machine-identity or disaster-recovery operations.
The recorded Kubernetes 1.37 compatibility gate still requires verification
against current Flux/CNI/CSI support before an approved production rollout.
Talos A/B boot rollback must be assessed against changed configuration and
extension requirements; Kubernetes downgrade must not be assumed supported.

## Public-readiness and recovery boundaries

Repository publication remains NO-GO pending controlled review of tracked files,
available history, personal infrastructure metadata, workflow/App permissions,
license selection and independent recovery evidence. A pattern scan or encrypted
Secret envelope check cannot certify a repository free of secrets. Keep detailed
findings outside the prospective public repository; never reproduce credential
values in an issue or PR.

No license is selected here. The owner may consider permissive MIT/Apache-2.0 or
copyleft GPL-3.0 licensing after considering reuse goals and third-party notices;
choosing a license and making a repository public are separate operator decisions.

Branch ahead counts do not prove unmerged work after squash merges. Inventory
ownership and semantic history before classifying removal candidates; delete no
branches as housekeeping. Historical Longhorn backups may be recovery points.

Local snapshots/replicas protect limited failure domains. A SYNC destination can
propagate deletion and is not an immutable backup. Verify destination versioning,
independent keys, isolated restore and offsite coverage for every data owner.
TrueNAS, LAN, OCI identity and the control server remain distinct dependencies.
GitOps reconstructs desired state, not databases, credentials or agent identity.
The OCI repository owns host/Vault/Hermes recovery; preserve disabled job state,
canonical wrapper dependencies and the saved lifecycle halt. Do not equate
ciphertext integrity checks with an application restore or safe Matrix identity
reuse. Existing OCI safety documentation already states these boundaries; this
mission requires no OCI code or host changes.
