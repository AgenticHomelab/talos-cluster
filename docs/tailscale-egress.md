# Private Kubernetes egress with Tailscale

Existing Tailscale operator-managed egress provides selected workload connectivity. Native Kubernetes policies and scoped Tailnet access stay authoritative; endpoints and device identities are private.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/tailscale-egress.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
