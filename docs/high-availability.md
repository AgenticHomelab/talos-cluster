# High availability and recovery targets

The production Talos cluster uses three physical control-plane nodes and
separately managed persistent storage, databases and NAS services. The intended
one-node failure behavior is not a guarantee against NAS, network or site-wide
failure. A Ready controller is not independent evidence of data recoverability.

The authoritative service classes, recovery budgets, actual endpoints and
protocol-aware verification policies are kept in the
[private availability policy](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/availability-policy.yaml)
and [private operations guide](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/high-availability.md).
Their exact-head offline validation is owned by the private repository.

This GitOps source retains generic, **non-production** policy fixtures for
fail-closed regression tests. Never use those test targets for live checks.
For a live read-only HA audit, pass the private policy explicitly to the
native `scripts/ha-audit.sh --policy PATH` command. Current runtime acceptance
requires a fresh authorized observation; dated HA exercise reports remain
[private](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/ha-reports/README.md).
