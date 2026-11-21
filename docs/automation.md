# Nightly Renovate dependency maintenance

Renovate discovers dependencies and opens update PRs, but does **not**
automerge them. The minimal
[GitHub Actions merge workflow](../.github/workflows/renovate-nightly-merge.yaml)
owns unattended PR merges between 00:00 and 04:00 Europe/Helsinki.
Longhorn chart updates retain their earlier 00:00–02:00 window.
Talos Linux and Kubernetes version upgrades remain excluded.

The scheduled sweep is requested every 15 minutes from 00:07 through 03:52
Europe/Helsinki, avoiding GitHub's busiest top-of-hour minute. New or updated
Renovate PR events trigger the same job immediately when GitHub delivers them.
It makes real squash-merge API calls for eligible PRs, with exact-head
protection and normal GitHub merge gates. It does not check out PR code, build
images, render charts, run tests or access the cluster. GitHub may delay or
drop scheduled runs despite this offset; the workflow checks the local clock
immediately before each merge and never starts a new merge from 04:00.

The existing `desired-state` CI job remains skipped for Renovate PRs;
a skipped job is not a successful validation. Flux deploys merged Kubernetes
state, and Hermes monitors deployments, repairs incidents and sends the
single 07:00 Finnish Matrix report. `antief/oci-control-server` owns
Hermes's native jobs and credentials. See
[the Renovate review policy](renovate-review-policy.md) and
[Longhorn upgrade guidance](longhorn-upgrade.md).

## Historical retirement boundary

The previous unattended classifier, review/merge orchestrators, guarded
GitHub runner, image publication workflow and mutable lifecycle/recovery
tools remain **retired**. The new narrowly scoped GitHub Actions merger is
independent of their saved state and credentials. Do not reactivate them
or clear any historical ambiguous-merge state.

Read-only `scripts/verify-change.sh` and
`scripts/automation/verify-renovate-change.sh` remain optional diagnostics;
the [private verification policy](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/verification-policy.yaml) is a health-target registry, not a
mutation controller. No retired maintenance framework is part of the
nightly workflow.

GitOps configuration cannot confirm Hermes's live cron status or Matrix
delivery. Keep runtime acceptance and incident investigation with the
appropriate operator and OCI runbooks.
