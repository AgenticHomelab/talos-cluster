# Hermes Agent

[Public OCI Ansible](https://github.com/AgenticHomelab/oci-control-server)
owns normal host configuration, and Flux owns Kubernetes resources.
The private `antief/oci-control-server` source owns the separate Hermes
operational playbooks. Protected endpoints, native job identities and privilege
boundaries belong in private operational documentation.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/hermes.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
