# Hermes messaging

Hermes runs on the OCI control server and uses Matrix as its messaging path.

The Matrix homeserver and application-service bridges remain independently
managed Talos workloads. Hermes is a Matrix client of that platform and
does not own the Signal or WhatsApp bridge workloads.

## Matrix path

    Matrix client or application-service bridge
        |
        v
    Matrix homeserver
        |
        v
    Hermes Matrix adapter on OCI
        |
        v
    Hermes sessions and agent state on OCI

Only explicitly approved Matrix users and rooms should reach Hermes.

Encrypted messaging credentials, device identity, recovery material and
room allowlists are runtime credentials owned by the OCI Hermes deployment.
They must not be committed to this repository.

## Talos ownership boundary

This repository owns the Matrix platform desired state.

It does not own:

- Hermes Matrix credentials;
- Hermes device encryption state;
- Hermes application state;
- a `hermes-matrix-runtime` Kubernetes Secret; or
- Hermes persistent volumes.

The former direct Hermes Signal workload remains retired. Signal and
WhatsApp connectivity is provided by their Matrix application-service
bridges.

## Security boundary

Messaging access does not weaken Hermes command or repository-maintenance
policy.

Repository mutation remains constrained by deterministic automation policy,
exact revision bindings and the guarded runner.

Runtime credential backup and recovery for Hermes belong to the OCI
deployment rather than Talos or Longhorn.
