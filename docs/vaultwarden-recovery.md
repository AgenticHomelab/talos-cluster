# Vaultwarden recovery and upgrade gates

Vaultwarden application recovery requires a consistent backup of its persistent SQLite/application data, compatible schema and a tested restore. Longhorn replica health and snapshot listings are not a validated application restore.

The exact runbook, machine/security identifiers, operator evidence and
recovery prerequisites are retained in the
[private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/vaultwarden-recovery.md).

All production operations still require their separately approved changes,
current source review and verified live acceptance.
