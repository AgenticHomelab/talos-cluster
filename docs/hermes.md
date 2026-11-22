# Hermes Agent

[Public OCI Ansible](https://github.com/AgenticHomelab/oci-control-server)
owns normal host configuration, and Flux owns Kubernetes resources.
The public OCI source also owns the isolated
[Hermes operational playbooks](https://github.com/AgenticHomelab/oci-control-server/blob/main/docs/hermes-operations-source.md). Protected endpoints, native job identities and privilege
boundaries belong in private operational documentation.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/hermes.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
