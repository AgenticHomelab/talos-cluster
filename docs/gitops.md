# Flux GitOps operations

This source declares Flux synchronization of `AgenticHomelab/talos-cluster` `main` from
`kubernetes/clusters/talos-home`. Git owns persistent Kubernetes
resources; **Omni separately owns Talos machine configuration**,
machine identities and operating-system upgrades. Do not apply
GitOps manifests directly during ordinary maintenance.

## Reconciliation hierarchy and ownership

```text
kubernetes/clusters/talos-home
  -> kubernetes/flux/repositories/ (shared sources)
  -> kubernetes/kustomization.yaml (unit registry)
  -> kubernetes/<category>/<unit>/ (unit-local Flux Kustomization)
  -> app/ and optionally config/
```

The registry lists exactly one directory reference per
reconciliation unit, ordered by category (`applications`,
`infrastructure`, `observability`) and then alphabetically.
The categories are filesystem organization only; they are not
Flux phases, ownership layers or dependencies. The registry
declares cluster membership without flattening workloads,
duplicating CRDs or inventing platform-wide phases. The parent
`apps` Flux Kustomization uses `wait: false`; individual units
report their own readiness.

Typical unit layout:

```text
kubernetes/<category>/<unit>/
  namespace.yaml
  kustomization.yaml
  ks.yaml                    # primary Flux Kustomization
  secrets-ks.yaml            # optional private SOPS Secret owner
  app/kustomization.yaml
  app/...                    # resources excluding private Secrets
  config-ks.yaml             # optional controller-dependent owner
  config/...                 # controller-dependent resources
```

Not every unit owns a Namespace (for example, units installed in
`flux-system`). Keep resource identity and Kustomize paths
stable. Use the owning app directory for Helm/OCI sources and
workload-specific Secrets, not a shared unowned chart directory.
Shared repositories belong in `kubernetes/flux/repositories/`.

Flux `dependsOn` expresses a **hard initial reconciliation
prerequisite**, including controllers/CRDs, storage classes,
required ingress/TLS, DNS publication or auth infrastructure.
It is not a universal order of runtime network requests.
Where a controller supplies CRDs required by the app, use a
separate local `config-ks.yaml` and explicit dependency.
Do not move controller-dependent CRs into an earlier phase.

## SOPS and storage boundaries

Kubernetes Secret manifests are SOPS-encrypted `*.sops.yaml`
resources kept in the permanently private
`AgenticHomelab/homelab-secrets` repository, under their original
`kubernetes/<category>/<unit>/app/` or `config/` paths. Its
`flux-system/homelab-secrets` GitRepository authenticates with
`flux-system/homelab-secrets-git`. Each unit-local `*-secrets`
Flux Kustomization reads only that private Git source and decrypts
with the existing `flux-system/sops-age` identity. The original
application/config Kustomization depends on its private Secret owner
but retains ownership of its workloads, databases, PVCs and policies.

During any future source or ownership transfer, first reconcile
`prune: false` in every old owner **before** removing its Secret
from the old Git source. After the new owner is Ready and its inventory
contains the existing Secret while the old inventory does not,
verify Secret object continuity and restore the old owner's
`prune: true`. Reverting Git alone is not a safe rollback if a
resource was already garbage-collected.

The separate `homelab-private-config` Flux Kustomization reads the nonsecret
`kubernetes/private-config` ConfigMap from the private Git source into
`flux-system`. Every domain-bearing application, DNS, ingress and infrastructure
unit depends on that owner and uses native `postBuild.substituteFrom` to resolve
`BASE_DOMAIN`. App labels and subdomains (such as `borg`, `matrix-auth` and
`truenas-api`) remain explicit in the application-owned manifests. Kubernetes service exposure is classified by the neutral `network-exposure`
annotation. The key is policy metadata, not a DNS hostname. Embedded shell scripts must use `$VAR` or Flux-escaped
`$${VAR}` rather than unescaped `${VAR}`; Matrix's core and bridge init containers use shell-native `$VAR` references
instead of `${VAR}` for runtime credentials, avoiding accidental strict Flux
substitution of Secret-backed process environment variables. Offline tests substitute a synthetic domain;
actual configured hostnames and dependent routes must remain unchanged on cutover.
A Ready source and successful offline rendering do not alone prove runtime acceptance.

The [External Secrets foundation](external-secrets.md) adds a controller/CRD unit
and a separately gated `ClusterSecretStore/oci-vault` config owner from private
Git. This is initial staging only: the existing 15 SOPS Secret owners and
consumer dependencies are unchanged, and no delivery cutover is implied.

Bootstrap age private keys and Git deploy credentials are kept
outside Git. Private ciphertext does not by itself establish a
recoverable backup. Never replace encrypted manifests with
placeholders, include decrypted values in PRs, or use direct Secret
patches as durable configuration.

Longhorn block storage, TrueNAS dynamically provisioned
NFS and static retained NAS PVs have distinct owners and
failure domains. Preserve PV/PVC prune/retain flags and
[recovery ownership](recovery-ownership-inventory.md).
Three replicas are not a database/media backup.
Ingress has separate internal/public Traefik planes;
each exposed route declares `network-exposure`. See
[architecture](architecture.md) and
[service exposure](service-exposure.md).

## Changes, automation and validation

For operator-authored changes, review the current `main`,
complete affected unit/directory and dependencies; open a
focused PR with Conventional Commits and exact-head CI.
Normal Flux reconciliation follows a reviewed merge.
Manual `flux reconcile`, `kubectl apply`, Helm upgrade,
suspend/resume, deletion and emergency patches require an
approved operational scope. Persist any authorized temporary
repair in Git.

**Renovate exception:** native Renovate merges eligible
patch/minor/major dependency PRs in the 00:00–03:59
Europe/Helsinki night window, Longhorn Helm PRs in
00:00–01:59. Talos and Kubernetes version changes are
excluded. Renovate-authored PRs now run the same offline
`desired-state` Actions job as other source changes. A skipped
or unsuccessful check is not passing validation. Hermes handles
post-merge health/repair and the daily 07:00 Matrix summary,
not routine merges. The public repository's workflow owns the nightly merge.
The workflow requires the repository variable
`RENOVATE_NIGHTLY_MERGE_ENABLED=true`.
See [Renovate policy](renovate-review-policy.md).

Local non-mutating validation:

```bash
./scripts/validate-reconciliation-unit-registry.sh
HELM_KUBERNETES_VERSION=v1.37.2 \
  HELM_CHARTS_DIR=/path/to/verified/chart-archives \
  ./scripts/validate-complete-desired-state.sh
git diff --check
```

The complete gate checks registry, Service Audience, Matrix
bridge contract, shell tests and Kubernetes desired state,
YAML/Kustomize renders, encrypted Secret envelopes and
generated-file/whitespace safety. It needs **exact upstream
chart archives** for offline Helm rendering. All source-change
PRs run its `Validate desired state / desired-state`
GitHub Actions job; inspect actual head status and failure
logs. Never mark an unsuccessful/ skipped run as passed.

For approved Omni drift inspection use the separate
[private Omni template tooling](https://github.com/AgenticHomelab/homelab-secrets/blob/main/talos/README.md) with a verified
machine identity mapping. It is read-only; `omnictl cluster template sync`
is a separate lifecycle mutation requiring explicit authorization.
Preserve hourly encrypted etcd backups.

Actual HA and verification policies are in the separate private source;
this repository runs only synthetic policy fixtures in CI. Supply the real
policy paths explicitly for live operator verification.

See [cluster maintenance](maintenance.md),
[bootstrap and recovery](bootstrap.md) and
[primary architecture](architecture.md).
