# WhatsApp bridge operations and acceptance

The WhatsApp bridge is an existing Flux-managed Matrix integration. Bridge encryption, registration and identities require protected operational procedures; runtime configuration is unchanged.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/matrix-whatsapp.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
