# Hermes scheduling and ownership boundary

Hermes gateway, dashboard, credentials, native scheduler and job definitions
belong to the [Hermes operations sources](https://github.com/AgenticHomelab/oci-control-server/blob/main/docs/hermes-operations-source.md). This document states the
current ownership policy, not proof of live job execution.

## Authorized native jobs

The documented `talos-nightly-health` job checks assigned cluster updates
every 30 minutes between 00:00 and 06:30 Europe/Helsinki and records locally;
it does not send Matrix progress messages. `talos-nightly-report` sends exactly
one concise Finnish Matrix summary at 07:00 daily, including when no changes
occurred. A separate daily 09:00 native administrator-JWT lifecycle job was
operator-authorized and acceptance-tested on 2026-10-29; the canonical
operator runbook is [OCI administrator JWT lifecycle](https://github.com/AgenticHomelab/homelab-secrets/blob/main/operations/hermes/runbooks/hermes-admin-jwt-renewal.md).
Check live native job registration/runs before treating any schedule or
credential renewal as currently healthy.

The dedicated GitHub Actions workflow, not Renovate or Hermes, merges eligible
dependency PRs from 00:00 to 03:59 Europe/Helsinki (Longhorn from 00:00 to 01:59).
Hermes may investigate and repair
assigned incidents, including persistent GitOps changes through reviewed PRs;
it does not routinely merge Renovate PRs. Its trusted-administrator authority
for `talos-home` and `control-01` does not extend to OKE or unrelated OCI
resources. See [the maintenance policy](renovate-review-policy.md),
[the current Hermes access contract](agents/hermes-operational-access.md),
and [OCI nightly maintenance](https://github.com/AgenticHomelab/homelab-secrets/blob/main/operations/hermes/runbooks/hermes-nightly-maintenance.md).

## Retired custom automation

The previous three custom maintenance jobs, runner, classifier, merger and
lifecycle orchestration remain disabled. Their saved lifecycle halt must not be
acknowledged, reset or reactivated. Retained security-watch sources and
recovery metadata are not evidence that old cron jobs should run. Retiring
code is separate from revoking GitHub App credentials, privileged sessions or
server-side tokens. Do not delete recovery material without an independently
approved inventory and rollback plan.
