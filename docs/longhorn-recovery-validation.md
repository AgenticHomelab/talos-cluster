# Longhorn backup recovery validation

Persistent volume and application recovery require independently validated backup artifacts, storage-engine compatibility and restore exercises. Replica health alone is not restoration assurance.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/longhorn-recovery-validation.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
