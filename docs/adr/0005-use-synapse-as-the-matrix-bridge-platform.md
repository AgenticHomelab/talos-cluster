# Use Synapse as the Matrix bridge platform

Synapse remains the established Matrix homeserver and bridge hub. Federation and deployed user/server identities are durable production contracts; this documentation move does not authorize changing them.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/adr/0005-use-synapse-as-the-matrix-bridge-platform.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
