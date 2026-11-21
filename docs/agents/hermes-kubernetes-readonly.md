# Hermes restricted Kubernetes inspection identity

Kubernetes runtime observation uses approved bounded identities through the Omni API access path. Native administrator privileges and read-only fallback identities have separate authorization and recovery contracts.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/agents/hermes-kubernetes-readonly.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
