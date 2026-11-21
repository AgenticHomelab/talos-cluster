# Authentik PostgreSQL backups

Authentik uses CloudNativePG with application-aware database recovery and independent backup integrity requirements. Healthy cluster and ObjectStore status do not prove a tested restore.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/authentik-postgres-backups.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
