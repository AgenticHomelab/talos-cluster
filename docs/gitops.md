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
  app/kustomization.yaml
  app/...                    # workload resources and ExternalSecrets
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

## Secrets and storage boundaries

Stable runtime credentials are canonical in OCI Vault. Flux owns app-local
ExternalSecret manifests; ESO owns synchronization of the corresponding
Kubernetes Secrets. Applications continue using their existing Secret names,
keys and types. Application-generated mutable credentials remain application-owned.
The private GitRepository remains necessary for noncredential configuration.
The 2026-11-24 cutover was accepted with 32/32 Secret UIDs, types, keys and
bytes unchanged, all ExternalSecrets and Flux units Ready, and applications
functional. Historical SOPS ciphertext is retained in private Git history;
age identities remain independently recoverable and are not runtime credentials.

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

The independent ESO controller has an
`external-secrets-config` Kustomization. The latter depends on both
the controller/CRDs and `homelab-private-config`. Its `oci-vault`
ClusterSecretStore uses an explicit OCI User Principal, the private
ConfigMap's `ESO_OCI_VAULT_OCID`, `ESO_OCI_REGION`,
`ESO_OCI_USER_OCID` and `ESO_OCI_TENANCY_OCID`, and the separately
bootstrapped `external-secrets/oci-vault-auth` Secret. Its API signing
key and fingerprint never enter Git. Restore that Secret independently
using the [OCI control-server bootstrap runbook](https://github.com/AgenticHomelab/oci-control-server/blob/main/docs/talos-secrets-bootstrap.md). ESO signs OCI HTTPS requests with its dedicated key and reads only individually allowed runtime bundles. No control-host relay or write access is required. Validate the Store's Ready condition and a bounded secret synchronization when recovering or changing its provider configuration.

For stable runtime credentials, put the ExternalSecret beside the workload in its
existing app or config path, and depend on `external-secrets-config`.
Do not retain a separate per-app Secret Kustomization unless a genuine
initial ordering requirement needs it. ESO periodically synchronizes the existing Secret
with `creationPolicy: Orphan` and `deletionPolicy: Retain`; removing the
ExternalSecret during a rollback does not garbage-collect the target.
The tradeoff is explicit cleanup when retiring a Secret in a surviving
namespace. Authentik's Helm values Secret carries the Flux watch label for prompt reconciliation when ESO creates or updates it. Preserve explicit non-Opaque Secret types and consumer reload labels.

Bootstrap API signing and Git deploy credentials are kept outside Git and
recovered independently of ESO. Keep historical age identities recoverable.
Never include credential values in PRs or use direct Secret patches as durable
configuration.

### Add or update a stable runtime credential

1. Confirm that the credential is stable and project-managed, not native
   application state, a controller-generated identity, or a bootstrap key.
2. The operator creates the approved JSON-map secret or updates its version in
   the existing OCI Vault, using the actual consumer key names. Coordinate
   related service-side changes and preserve required prior versions for recovery.
3. For a new bundle, the operator adds its exact OCID to the protected
   OpenTofu runtime allowlist under the [OCI IAM contract](https://github.com/AgenticHomelab/oci-control-server/blob/main/docs/talos-eso-iam.md).
   IAM changes require separate plan/apply approval. Never broaden access to
   a whole compartment or give ESO access to bootstrap credentials.
4. Declare an app-local ExternalSecret with the exact Vault secret **name**
   in `dataFrom.extract.key`, the established target name/type/metadata,
   `refreshInterval: 1h`, `creationPolicy: Orphan`, `deletionPolicy: Retain`,
   and the shared store `oci-vault`. Register it in the local Kustomize root.
   Use an existing declaration as the structural example.
5. Review the PR and exact-head CI; after merge, check the store and target
   synchronization and actual application consumption. Verify data key names,
   type and any expected equality without dumping Secret values. ESO updates
   Kubernetes Secret data, not the upstream service account or database password.
   Environment-variable consumers may need a separately authorized rollout;
   mounted Secrets and native reload/watch consumers have different semantics.

Read-only diagnosis:

```bash
kubectl get clustersecretstore oci-vault
kubectl get externalsecrets -A
flux get kustomizations -A --status-selector ready=false
```

On provider failure, the configured Orphan/Retain policy preserves existing
consumer objects; a missing Secret cannot be reconstructed until Vault access
returns. Investigate Store/ExternalSecret conditions, access and refresh age
before modifying anything. Do not delete existing Secrets to force a retry.
This retention is desired behavior, not a completed outage exercise.

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

**Renovate exception:** the dedicated GitHub Actions workflow merges eligible
Renovate patch/minor/major dependency PRs in the 00:00–03:59
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
YAML/Kustomize renders, ExternalSecret delivery contracts, absence of active encrypted or plaintext Secret manifests and
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
