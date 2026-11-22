# Kubernetes GitOps bootstrap and recovery

Omni owns the Talos cluster, machine identities, network patches and etcd
recovery. The authoritative machine-specific bootstrap, full template
validation, read-only Omni drift comparison and approved template-sync procedure
are in the [private Omni bootstrap runbook](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/bootstrap.md).
Do not re-create machines or attempt an Omni sync from this GitOps repository.

This repository owns the persistent Kubernetes desired state and Flux bootstrap
entrypoint. The existing cluster's normal API path is the Omni Kubernetes API
proxy; emergency direct node access is a separately controlled fallback.

## 3. Obtain normal Kubernetes API access

Download an OIDC-authenticated kubeconfig through Omni into a local ignored or temporary path:

```bash
omnictl kubeconfig /tmp/talos-home.kubeconfig \
  --cluster talos-home \
  --merge=false

export KUBECONFIG=/tmp/talos-home.kubeconfig
kubectl get nodes -o wide
```

Expected: three Ready control-plane nodes. Do not use `--break-glass` for normal bootstrap verification.

## 4. Bootstrap Flux prerequisites

Create the `flux-system` namespace and provision the two bootstrap Secrets outside Git:

- `flux-system/sops-age` from the authorized age recovery identity.
- `flux-system/homelab-secrets-git` with the independent read-only SSH deploy key for `AgenticHomelab/homelab-secrets` and verified `known_hosts` entries.

The production `flux-system` source reads `AgenticHomelab/talos-cluster`
over anonymous HTTPS. `AgenticHomelab/homelab-secrets` is the independent
private source and keeps its own read-only SSH deploy identity. Neither
source requires a new age identity.

For source recovery, use the last accepted GitOps revision in this public
repository and the matching private source revision from reconciliation
evidence. Verify that the exact commits are independently reachable and that
the two off-Git bootstrap identities remain available. Reconstruct the
public HTTPS and independent private SSH sources with their existing Flux
resource identities. A source, revision, credential or prune change requires
a separately reviewed recovery plan. A Git revert cannot undo pruning.

The former `antief/talos-homelab` SSH source is historical. The recovery
procedure uses the two current sources above. Preserve any historical deploy
credential until its own authorized credential review.
Keep all private identities out of Git and logs. Register only the corresponding
public SSH key as a read-only deploy key on the private repository.

Before any application Secret ownership transfer, verify the new private source and configuration:

```bash
flux -n flux-system get sources git homelab-secrets
flux -n flux-system get kustomizations homelab-private-config
kubectl -n flux-system get configmap homelab-private-vars -o name
```

Both Flux resources must be Ready and the ConfigMap must exist at the expected private Git revision. The private source is deliberately independent of `repositories` and `apps`, so missing credentials do not block current application reconciliation. Do not move Secret manifests or change existing prune ownership until separate transfer checks pass.

## 5. Install Flux Operator and hand ownership to Git

Install the Flux Operator Helm release in `flux-system` at the currently validated chart version. Then apply the repository entrypoint once to create the `FluxInstance` and cluster-level Flux Kustomizations:

```bash
helm upgrade --install flux-operator \
  oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --namespace flux-system \
  --version 0.61.0

kubectl apply -k kubernetes/clusters/talos-home
```

The `flux-operator` reconciliation unit then adopts the same Helm release through
a pinned `HelmRelease`; it does not create a second operator or own the
`flux-system` namespace. See [Flux upgrades](flux-upgrades.md) for the explicit
ownership and recovery gates.

This one-time bootstrap apply establishes the Git source. After the `FluxInstance` becomes Ready, Flux owns persistent Kubernetes state and normal changes arrive through `main`; do not manually apply application directories.

For operator-run HA verification, set `PRIVATE_SOURCE_DIR` to the local
checked-out `AgenticHomelab/homelab-secrets` repository before running the
audit command below. Do not use public CI fixtures for live checks.

## 6. Verify convergence

Run the read-only policy and cluster audits:

```bash
kubectl get nodes -o wide
kubectl -n flux-system get fluxinstance
kubectl -n flux-system get kustomizations.kustomize.toolkit.fluxcd.io
./scripts/validate-reconciliation-unit-registry.sh
./scripts/validate-service-audiences.sh
./scripts/ha-audit.sh --policy "$PRIVATE_SOURCE_DIR/docs/availability-policy.yaml"
```

Success requires:

- three Ready and schedulable Kubernetes and Longhorn nodes;
- all Flux Kustomizations Ready at the intended Git revision;
- three healthy Longhorn replicas on three distinct nodes for every production volume;
- Authentik PostgreSQL healthy at three instances;
- DNS, ingress, authentication and representative storage I/O working from outside the cluster;
- every reconciliation unit healthy without plaintext secret or generated credential material in Git.

## Recovery boundary

See [Omni-managed etcd backups](etcd-backups.md) for the hourly schedule,
activation evidence, independent encryption-state requirements and the isolated
restore gate. An Omni application backup alone does not contain a cluster etcd
snapshot; both recovery paths are needed.

Omni and its etcd backups recover Talos and Kubernetes control-plane state. Git and the bootstrap Secrets recover Flux ownership. Longhorn and application-aware backups recover persistent application data. TrueNAS-hosted backups remain inside the TrueNAS/LAN failure domain and are not offsite disaster recovery.

A recovered or reinstalled node remains cordoned until `scripts/node-rejoin-network-check.sh` passes. Follow `docs/maintenance.md` for the one-node-at-a-time return-to-service procedure.
