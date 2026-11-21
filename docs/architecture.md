# Architecture

This document defines the intended architecture and the invariants that repository changes must preserve. Operational procedures belong in the corresponding runbooks.

## Target cluster

The target cluster is a production-like personal Talos Kubernetes platform with three control-plane nodes. These are physical mini PCs running Talos on bare metal, not virtual machines on TrueNAS. Each node has a dedicated local non-system NVMe volume for Longhorn data; TrueNAS is a separate NAS and failure domain for selected NFS workloads and backups. Omni manages machine lifecycle and applies Talos configuration. The shared platform path is designed to tolerate the loss of one Kubernetes node, although workload-specific recovery objectives and external dependencies can impose narrower guarantees.

Git owns the persistent desired state:

- Kubernetes resources are reconciled by Flux from `main`.
- Non-secret Talos machine configuration is maintained declaratively in Git and applied through Omni.
- Generated Talos configuration, credentials, private keys and other secret material remain outside Git.

Direct cluster changes are exceptional operational actions. Any persistent emergency change must be represented in Git afterwards.

Operators use the Omni API Access Path for normal Kubernetes administration. Emergency Direct API Access may target any healthy control-plane node, but it is a break-glass fallback without a stable endpoint or a single-node availability guarantee. The target cluster does not maintain a Talos virtual IP; see ADR-0004.

## Repository and reconciliation model

Flux enters the repository at `kubernetes/clusters/talos-home`. The cluster-level hierarchy is:

```text
repositories -> apps -> reconciliation units
```

The `flux-system/apps` Kustomization path is `./kubernetes`; the three category directories are plain top-level groupings inside that tree, not extra Flux roots.

`kubernetes/flux/repositories/` owns sources shared by multiple units. `kubernetes/kustomization.yaml` is the Reconciliation Unit Registry: a list containing exactly one directory reference for every unit under `kubernetes/`.

Units are grouped into three organizational categories under `kubernetes/`: `applications/`, `infrastructure/` and `observability/`. These categories are filesystem organization only — they are not Flux deployment phases, ownership boundaries or dependency layers. Registry entries are sorted by category, then alphabetically, so the whole list remains deterministic.

The registry declares only cluster membership. It does not contain workload resources, own shared policies, express platform phases, apply cross-unit patches or duplicate the Flux dependency graph. The `apps` Flux Kustomization uses `wait: false`: it is ready after registering units, while each child Kustomization reports its own readiness.

Platform and workload units deliberately reconcile independently; the categories do not change that. The repository does not use broad infrastructure phases: unit-local ownership and explicit dependencies make the actual reconciliation graph visible.

A normal unit follows this layout:

```text
kubernetes/<category>/<unit>/
├── namespace.yaml
├── kustomization.yaml
├── ks.yaml
└── app/
    ├── kustomization.yaml
    └── ...
```

`ks.yaml` is reserved for the primary Flux `Kustomization`. Resources that require a controller or its CRDs use a second `<unit>-config` Flux Kustomization in `config-ks.yaml` and manifests under `config/`.

The directory name and primary Flux Kustomization name form the canonical unit identity. A namespace may follow an upstream convention, such as `cnpg-system`, `longhorn-system` or `metallb-system`. The canonical Flux web UI unit name is `flux-web-ui`.

A unit normally owns its namespace. A unit installed deliberately into a namespace owned by bootstrap or another platform unit must not declare that namespace as its own resource. This exception requires an explicit reason; in particular, `flux-web-ui` installs resources into `flux-system` without owning the namespace.

## Dependency semantics

Flux `dependsOn` represents a hard reconciliation prerequisite. A dependency belongs in the graph when the dependent unit cannot reach a valid initial deployment without it, for example because it supplies:

- a required controller or CRD;
- a StorageClass or CSI driver;
- mandatory ingress, load-balancing, certificate or authentication capability; or
- DNS publication required by the service's accepted exposure model.

Dependencies are not used for cosmetic ordering, every runtime network relationship, or precautionary serialization. A new dependency must be explainable as: “X cannot achieve an accepted initial deployment without Y because …”.

## Secrets

Every Kubernetes Secret stored in Git is a SOPS-encrypted `*.sops.yaml` manifest governed by `.sops.yaml`. The owning reconciliation unit declares Flux SOPS decryption explicitly with `flux-system/sops-age`; global decryption support does not replace unit-local declaration.

`sops-age` is a bootstrap secret created outside Git. AGE private keys, Talos secrets and generated credentials are never committed. Encrypted values are changed with SOPS tooling rather than by editing ciphertext manually. The two configured AGE recipients provide key-management and recovery redundancy.

## Storage architecture

The platform has three storage classes of use:

- **Cluster Storage** uses Longhorn block volumes replicated across the three Talos nodes. It is the default for persistent application data that must tolerate a Kubernetes-node failure.
- **Shared Storage** uses dynamically provisioned TrueNAS NFS when RWX or NAS semantics are required.
- **Static NAS Storage** maps a specifically named, externally managed TrueNAS dataset through a static PersistentVolume.

TrueNAS and the LAN are a separate failure domain and an accepted single point of failure for NFS-dependent workloads. A Longhorn backup stored on the same TrueNAS system is an operational recovery copy, not an independent disaster-recovery copy. Disaster recovery requires a copy outside that failure domain.

TrueNAS-side infrastructure is intentionally managed separately from Flux.
[`antief/truenas-infra`](https://github.com/antief/truenas-infra) owns the
existing ACME OpenTofu configuration and is the selected future owner for
verified stable NAS parents, intentionally static NFS exports, selected native
protection tasks, and service identity/permission metadata. Not every TrueNAS
resource belongs in OpenTofu. The official TrueNAS CSI driver retains sole
lifecycle ownership of the child ZFS datasets and NFS exports it provisions
for PVCs; never dual-manage them through TrueNAS OpenTofu. The CSI driver,
StorageClasses and PVC manifests remain Flux-owned in this repository.

For stable TrueNAS service credentials, OCI Vault is the intended canonical
value and selected-version authority. Flux/SOPS remains the Kubernetes Secret
delivery mechanism, and deployed SOPS ciphertext is not evidence that its
current value has been verified against Vault. Preserve existing credentials
until a separately validated, no-rotation adoption. Protected OpenTofu state
may contain sensitive copies, but is not the password authority. Future public
repository publication requires a separate audit of files, history and metadata.

Authentik PostgreSQL uses the CloudNativePG Barman Cloud Plugin for continuous
WAL archiving and daily base backups to the externally managed Garage service
on TrueNAS. This is an application-aware operational recovery path, but it
shares the TrueNAS/LAN failure domain and is not an offsite copy.

The Matrix foundation follows the same database recovery pattern with its own
Garage bucket and credentials. Synapse media and all Matrix database volumes
remain on Longhorn; no active Matrix state uses NFS. The permanent Matrix
Server Name `${BASE_DOMAIN}` is delegated to `matrix.${BASE_DOMAIN}:443`, keeping user IDs
stable while the public service hostname remains independently operable. See
[`matrix.md`](matrix.md) for its public boundary and restore procedure.

Longhorn replication protects storage data from a node or disk loss. It does not make singleton stateful software highly available.

## Networking and ingress

Every exposed service has an explicit audience: `public`, `internal`, or `port-forward`. New services default to `internal`; public exposure requires a service-specific authentication and threat-model decision.

The owning exposed resource declares this Service Audience with the `network-exposure` annotation. The annotation records policy and does not itself publish DNS, open a firewall or change a load balancer. `docs/service-exposure.md` records the current intended split and its audit procedure.

HTTP/HTTPS ingress is split into two independent network planes backed by the same Traefik Deployment:

- **Internal Web Ingress** uses the `web`/`websecure` entrypoints through the MetalLB address `${TRAEFIK_LAN_IP}`. It serves only `internal` routes. The same internal Service intentionally exposes BorgWarehouse TCP/2222.
- **Public Web Ingress** uses the `web-public`/`websecure-pub` entrypoints through the MetalLB address `${TRAEFIK_PUBLIC_IP}`. It serves only `public` routes and exposes no SSH, dashboard, metrics or admin port. OPNsense forwards public HTTPS only to this plane.

A web route belongs to exactly one plane. A public route must not bind an internal web entrypoint, and an internal route must not bind a public web entrypoint. Cloudflare is authoritative for `${BASE_DOMAIN}`: private web names resolve to the internal Traefik address, while public names resolve through the home public endpoint and OPNsense forwards HTTPS to the public Traefik plane. DNS publication alone is never treated as an access-control boundary.

- **Dedicated Service Exposure** uses a service-specific MetalLB address when TCP or UDP protocol requirements justify it.
- Shared Traefik TCP entrypoints are used only when the protocol can be routed safely and sharing the ingress address is intentional.
- **Internal Admin Services** are not published through ingress and are accessed through the LAN, Tailnet or an explicit port-forward.

MetalLB provides LAN addresses, cert-manager obtains certificates, ExternalDNS manages Cloudflare records, and Cloudflare DDNS tracks the home endpoint. A DNS record does not by itself mean a service is intended for public access.

## Updates and rollback

Renovate creates eligible patch, minor and major dependency PRs. The dedicated
GitHub Actions workflow merges them from 00:00 to 03:59 Europe/Helsinki
(Longhorn chart/manager PRs from 00:00 to 01:59). Talos Linux and Kubernetes
version changes are excluded and require separate operator-approved Omni
procedures. `renovate.json` disables Renovate's own automerge; GitHub Actions
intentionally skips `desired-state` for Renovate-authored PRs. Skipped CI is not a passed
validation. Other changes retain operator review and the normal CI gate.

Flux normally reconciles merged Kubernetes changes. Hermes independently
monitors deployed changes, diagnoses assigned incidents, and sends one Finnish
Matrix summary at 07:00; it does not routinely merge Renovate PRs. A successful
merge or Ready controller does not prove functional acceptance. Verify service
health, storage engines/replicas and backup dependencies where relevant. A
reviewed Git revert can reverse eligible desired-state configuration, but not
on-disk Longhorn engines, databases, CRDs or Talos upgrades.

The retired custom Hermes runner, merger and lifecycle jobs remain disabled.
See [the current Renovate policy](renovate-review-policy.md),
[native automation ownership](automation.md) and
[Longhorn upgrade policy](longhorn-upgrade.md).

## Talos and Kubernetes maintenance

Talos and Kubernetes upgrades are separate changes and separate maintenance operations. Omni performs a one-node-at-a-time rollout. Before each node, verify the control plane, etcd, Flux, Longhorn, CloudNativePG, DNS and ingress path.

Do not proceed to the next node until the previous node is Ready and schedulable, the overlay network check passes, and storage and database replication are healthy. Pause explicitly after the first node and stop the rollout on any unexpected result. Do not combine a Longhorn replica migration with node maintenance.

## External dependencies

The platform's availability also depends on systems outside Kubernetes:

- TrueNAS and the LAN for NFS and the current Longhorn backup target;
- OPNsense and Tailscale for remote network access;
- Cloudflare for public DNS and DDNS;
- Let's Encrypt for public certificates; and
- upstream chart, image and artifact registries during installation and upgrades.

These dependencies are not covered by the one-Kubernetes-node failure guarantee.

## Validation evidence

The repository-side validation gate is
`./scripts/validate-complete-desired-state.sh`, which validates the Flux
reconciliation registry, exposure classifications, Matrix bridge contract,
rendered Kubernetes resources and repository safety. Separate private-source
CI validates Talos/Omni templates, availability policy and operator verification
contracts. An authorized [private Omni drift check](https://github.com/AgenticHomelab/homelab-secrets/blob/main/talos/README.md)
compares actual machine configuration, not the public Kubernetes GitOps gate.

The live-cluster and runbook side of the loop lives in
[`docs/bootstrap.md`](bootstrap.md),
[`docs/ha-failure-testing.md`](ha-failure-testing.md), and
[private historical HA evidence](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/ha-reports/README.md). Together they record the
operational checkpoints and the accepted three-node Talos cluster behavior,
including the final voluntary and sudden tests for the three control-plane
failure domains.
