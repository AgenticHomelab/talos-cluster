# Matrix homeserver operations

Matrix Synapse, Matrix Authentication Service and bridges retain their deployed immutable identity contracts. Do not change federation server name, signing material, user IDs or service URLs as part of repository publication.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/matrix.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
