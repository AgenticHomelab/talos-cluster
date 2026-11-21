# E-books

The book-service workload remains under the existing `kubernetes/applications/ebooks/` Flux reconciliation unit. Storage, credentials and ingress are not changed by this documentation move.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/ebooks.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
