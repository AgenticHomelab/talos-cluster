# Agent operating model

Flux uses this repository for Kubernetes desired state. The permanently private
`AgenticHomelab/homelab-secrets` repository supplies private noncredential configuration and the Talos/Omni template and patches. OCI Vault and ESO deliver stable runtime credentials. Three physical Talos nodes
use local Longhorn NVMe. TrueNAS is a separate NAS and backup failure domain.
TrueNAS CSI owns the PVC datasets and exports it creates.

The public OCI source owns the isolated Hermes Ansible playbooks.
`AgenticHomelab/homelab-secrets/operations/hermes/` provides their protected
assets and runbooks, including fleet monitoring and native renewal.

## Authorization and source of truth

Hermes is a trusted administrator **within assigned** `talos-home`
and `control-01` incidents, with native Kubernetes, Omni Operator
and host sudo privileges. The original read-only inspection identity
remains as a fallback. Assignment covers necessary diagnostics and
supported incident repair, not arbitrary unrelated work. OKE,
other OCI resources, destructive restoration, visibility changes
and blanket merge privileges are excluded. Read
[administrator access](hermes-operational-access.md).

| Owner | Persistent configuration |
| --- | --- |
| Flux | Kubernetes resources in `kubernetes/` and Secret delivery from the private source |
| Omni | Talos lifecycle, machine identities, applied cluster template and encrypted etcd snapshots |
| OCI OpenTofu (`AgenticHomelab/oci-control-server`) | OCI infrastructure, policies and Vault/IAM metadata |
| TrueNAS OpenTofu (`AgenticHomelab/truenas-infra`) | ACME, selected stable storage resources, service identities and native policies |
| Normal OCI Ansible (`AgenticHomelab/oci-control-server`) | Persistent control-01 host configuration and services |
| Native apps | Databases, media, mutable sessions, encryption material and recovery data |

Ordinary assistant tasks remain read-only unless separately assigned
or approved. A runbook command is **not** permission to run it.
Review the current `main`, `AGENTS.md`, relevant implementation,
and scoped runbook before proposing changes.

## Repository change procedure

1. Establish exact current Git and any approved live-state evidence.
   Distinguish desired state, dated runtime, fresh measurements and
   unknown. Never treat a green controller as application acceptance.
2. Inspect affected app directories, Kustomize ownership,
   dependencies, PVC retention, ExternalSecret delivery and external
   failure domains. Preserve unrelated changes and private keys.
3. Use focused branches and Conventional Commits. Validate exact-head
   changes and current-main integration, run non-mutating checks,
   `git diff --check`, and review the full diff for sensitive data.
4. Open PRs for operator review or a specific authorized autonomous
   merge. Do not directly push `main` or bypass required CI.
   The dedicated GitHub Actions night merger is the explicit separate
   policy, **not** Hermes's routine merge responsibility.
5. For an assigned incident, prefer native controller/tool repair.
   Bound any temporary drift and commit persistent repairs in the
   owning declarative source. Verify actual application/data-plane
   behavior and report any missing evidence or recovery risks.

The retired bespoke Renovate runner/merger, dashboard guard and old
lifecycle jobs remain disabled; the minimal GitHub Actions merge workflow is
independent of those retired components. Native overnight Hermes health checks
record locally; one Finnish Matrix summary is sent at 07:00
Europe/Helsinki. See [native Renovate policy](../renovate-review-policy.md)
and [OCI nightly maintenance](https://github.com/AgenticHomelab/homelab-secrets/blob/main/operations/hermes/runbooks/hermes-nightly-maintenance.md).

## Safety and recovery boundaries

- Generated Talos secrets, kubeconfigs, age private identities,
  Git/bootstrap keys, operator OCI access and protected recovery
  material remain outside Git. Historical encrypted files are not proof of recoverable keys.
- Omni's hourly encrypted etcd snapshots, Omni application archives,
  Longhorn replicas/backups, CNPG WAL/base backups and NAS media
  snapshots protect **different** layers. A saved backup is not a
  tested complete restore.
- Before Talos template sync inspect the entire rendered, current
  machine-identity diff. Preserve the hourly etcd backup setting
  and approve upgrade sequencing independently of Flux.
- Do not blindly downgrade Longhorn engines, CRDs, Talos,
  PostgreSQL or app schemas; inspect actual per-volume engine/replica
  state and recover through supported version-matched procedures.
- Keep Tailnet/LAN and public ingress/DNS planes separate.
  Do not widen listeners, publish credentials or restore old
  E2EE device state alongside a running original instance.
- Host root and OCI Instance Principal are capabilities, not
  isolation or tamper-proof audit evidence. Protect independent
  operator recovery and limit tool execution to the assignment.

See [recovery ownership](../recovery-ownership-inventory.md),
[architecture](../architecture.md), and
[cluster maintenance](../maintenance.md).
