# Cluster DNS availability overlay

Talos bootstraps and retains ownership of the `kube-system/coredns`
Deployment, its image, Service and Corefile. This Flux reconciliation unit owns
only the Deployment pod anti-affinity field and the PodDisruptionBudget needed
for single-node tolerance.

The immutable Deployment selector and its matching pod label are repeated
because Kubernetes requires them during server-side dry-run. Their values match
the Talos-generated resource.

The Deployment manifest is intentionally a server-side apply overlay rather
than a complete copy of the Talos-generated resource. Keeping the ownership
boundary narrow allows Talos upgrades to change the bootstrap manifest without
forking it in this repository.
