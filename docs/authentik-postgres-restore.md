# Authentik PostgreSQL restore exercise

Authentik PostgreSQL recovery uses the supported CloudNativePG/Barman restore workflow in an isolated cluster, never in-place writes to a production database. Current backup, WAL integrity and independent restore acceptance are separate gates.

The exact runbook, machine/security identifiers, operator evidence and
recovery prerequisites are retained in the
[private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/authentik-postgres-restore.md).

All production operations still require their separately approved changes,
current source review and verified live acceptance.
