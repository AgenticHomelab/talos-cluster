# Talos Homelab

A production-like personal Kubernetes platform whose persistent desired state is managed declaratively in Git.

## Language

**Target Cluster**:
The canonical three-control-plane-node Talos cluster managed operationally through Omni.
_Avoid_: Single-node cluster, test cluster

**Talos Source Configuration**:
The private `AgenticHomelab/homelab-secrets/talos/` version-controlled source expresses machine-level choices while Omni retains machine identity, trust material, and generated base configuration.
_Avoid_: Generated machine config, local Talos config

**Omni API Access Path**:
The canonical operator path to the target cluster's Kubernetes API through Omni.
_Avoid_: Talos VIP, node kubeconfig

**Emergency Direct API Access**:
A fallback Kubernetes API connection to one healthy control-plane node, without a stable virtual endpoint or a single-node availability guarantee.
_Avoid_: Primary API endpoint, cluster VIP

**Reconciliation Unit**:
A self-contained set of resources owned by one repository directory and reconciled independently by Flux.
_Avoid_: App, component, package

**Reconciliation Unit Registry**:
The Kustomize aggregation that explicitly declares which reconciliation units belong to the target cluster without owning their workload resources or ordering their reconciliation.
_Avoid_: Apps aggregation layer, app bundle, infrastructure layer

**Platform Unit**:
A reconciliation unit that provides a cluster capability consumed by other units.
_Avoid_: Infrastructure layer, system app

**Workload Unit**:
A reconciliation unit that provides a service to a user or an external system.
_Avoid_: User app, leaf app

**Hard Reconciliation Prerequisite**:
A dependency that must reconcile successfully before another reconciliation unit can achieve a valid initial deployment.
_Avoid_: Startup order, soft dependency

**Cluster Storage**:
Longhorn-backed block storage replicated across Talos nodes.

**Shared Storage**:
Dynamic TrueNAS-backed NFS storage whose availability depends on TrueNAS and the LAN.

**Static NAS Storage**:
A named TrueNAS dataset mounted through a static PersistentVolume and managed outside the Kubernetes resource lifecycle.

**Bootstrap Secret**:
The `flux-system/sops-age` Secret created outside Git so Flux can decrypt Git-tracked secrets.

**Git-tracked Secret**:
A SOPS-encrypted Kubernetes Secret manifest named `*.sops.yaml`.

**Web Ingress**:
HTTP or HTTPS exposure through Traefik.

**Service Audience**:
The explicitly declared reachability class of an exposed service: `public`, `internal`, or `port-forward`.
_Avoid_: DNS visibility, assumed exposure

**Dedicated Service Exposure**:
Direct TCP or UDP exposure through a service-specific MetalLB address.

**Internal Admin Service**:
An administrative service available only through the LAN, Tailnet, or an explicit port-forward.

**Availability-Critical Stateless Service**:
A stateless service on the shared platform path or a user-facing request path whose loss with one Kubernetes node would violate the target cluster's availability guarantee.
_Avoid_: Every deployment, highly available app

**Seamless Service**:
A service whose accepted one-node-failure behavior is continued request handling without manual recovery.
_Avoid_: Zero-failure guarantee, replicated deployment

**Bounded-Recovery Service**:
A singleton stateful service allowed to interrupt active sessions when one node fails, provided it restarts automatically within its declared recovery budget with no observed persistent data loss.
_Avoid_: Highly available service, manual-recovery service

**Shared Platform Path**:
The runtime path that carries existing user traffic and persistent cluster I/O through networking, DNS, ingress, authentication, and storage during a Kubernetes-node failure.
_Avoid_: Every platform controller, management plane

**HA Canary**:
A workload unit containing only synthetic data and endpoints used to measure request-path continuity and storage recovery during a Kubernetes-node failure.
_Avoid_: Production health check, user-data probe

**External HA Probe**:
A request issued from outside the target cluster but within the LAN or Tailnet failure boundary to measure the shared platform path without adding unrelated internet dependencies.
_Avoid_: In-cluster health check, internet uptime monitor

**Federation-Capable Matrix Homeserver**:
A Matrix homeserver whose identity, routing and deployment boundaries preserve the option to exchange events with other Matrix homeservers, whether federation is enabled initially or later.
_Avoid_: Private chat server, Hermes Matrix bridge

**Matrix Server Name**:
The permanent `${BASE_DOMAIN}` Matrix identity embedded in user IDs, room IDs and federation signatures, delegated to the homeserver endpoint. The actual deployed identity must never change during publication.
_Avoid_: Matrix hostname, homeserver URL

**Matrix Bridge Platform**:
The federation-capable Matrix service that provides local rooms and identities and forms the canonical messaging path between Hermes and selected external messaging networks through application services.
_Avoid_: Hermes Matrix adapter, chat bridge

**Matrix Identity Chain**:
The authentication boundary in which Matrix Authentication Service owns Matrix sessions and delegates human authentication to Authentik while preserving the Matrix Server Name identities.
_Avoid_: Synapse login, Authentik user

**Bridge Trust Boundary**:
The point where an application-service bridge decrypts Matrix room events and holds the external network session needed to re-encrypt and deliver them; Matrix room encryption does not hide message content from the bridge.
_Avoid_: End-to-end bridge, transparent relay
