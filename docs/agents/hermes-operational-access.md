# Trusted Hermes administration of talos-home

Hermes is permitted to perform only assigned, authorized Talos/`control-01` operations under the approved administrator contract. Native security boundaries, least privilege, independent recovery and GitOps/Omni ownership remain mandatory. Access to unrelated OCI resources and OKE is never authorized.

The exact runbook, machine/security identifiers, operator evidence and
recovery prerequisites are retained in the
[private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/agents/hermes-operational-access.md).

The original read-only administrator acceptance test is owned by
[OCI control-server](https://github.com/antief/oci-control-server/blob/main/scripts/manual/hermes-diagnostics-acceptance.sh), with matching original Git blob and executable mode. It does not belong to this Flux repository.

All production operations still require their separately approved changes,
current source review and verified live acceptance.
