# Renovate review and nightly automerge policy

## Authorized automation

Renovate discovers dependency updates and creates PRs; the lightweight
[`renovate-nightly-merge.yaml`](../.github/workflows/renovate-nightly-merge.yaml)
GitHub Actions workflow performs eligible unattended merges. Renovate's own
`automerge` is disabled, including a final catch-all package rule to override
any inherited merge policy. Flux reconciles merged Kubernetes changes. Hermes
independently monitors and repairs runtime failures.

- General merge window: **00:00–03:59** in `Europe/Helsinki`, including DST.
- Longhorn dependency PR window: **00:00–01:59**.
- Eligible patch, minor and major dependency updates are merged with squash.
- **Talos Linux and Kubernetes versions are owned by the private Omni source.**
  Their PRs are never merged by this workflow and require the separate Omni
  upgrade procedure.
- No new CI, Helm rendering, cluster access or custom service is required.

The independent `control-01` systemd timer submits a `repository_dispatch`
event of type `renovate-nightly-merge` at 00:15 and 00:45 in each hour from
00:00 through 03:59 (`Europe/Helsinki`). This dispatch triggers the **same**
GitHub Actions merger; no host-side PR selection or merge happens. GitHub's
`pull_request_target` events still trigger it on Renovate PR activity.

The GitHub `schedule` also requests fallback sweeps every 15 minutes from
00:07 through 03:52. GitHub-hosted scheduled jobs may start hours late or be
dropped. Every workflow invocation checks Finland local time again. No merge
starts at or after 04:00.
A successful out-of-window job means no merge was attempted.

The workflow uses the default-branch definition, never checks out or executes
PR content, and authenticates using the job-scoped `GITHUB_TOKEN`. It only
selects open, non-draft `renovate[bot]` PRs with a same-repository
`renovate/` branch and `dependencies` label. It excludes PR descriptions identifying `siderolabs/talos` or
`kubernetes/kubernetes` upgrades. Longhorn PRs are restricted to the
earlier window. It attempts real GitHub API merges with an exact PR-head SHA,
then refreshes the queue after each successful merge. A blocked merge is logged
as an Actions warning/failure; normal GitHub protection is never bypassed.

A mixed update containing excluded Talos/Kubernetes version changes is not
eligible. Review actual changes and track Talos/Kubernetes version PRs in the
[private owner repository](https://github.com/AgenticHomelab/homelab-secrets/blob/main/talos/README.md). Labels alone are not sufficient proof of eligibility.

## CI and runtime boundaries

The existing `Validate desired state / desired-state` offline check runs for
Renovate-authored PRs and other PRs, including documentation-only PRs. It
catches rendering, dependency, exposure and policy regressions before the
nightly merge.
The same exact-head job and required-check enforcement apply to both types of
PR; an incomplete, skipped or failed check is not passing validation. The
nightly merger still uses the native GitHub API with normal branch protection
and never executes PR code with write permission. Flux reconciliation and Hermes
monitoring/repair remain separate post-merge acceptance layers. Do not claim
that a passing offline check establishes application health.

For Longhorn, chart/manager upgrades and running V1 volume-engine/replica
updates remain distinct stages. Longhorn's native concurrent automatic engine
upgrade limit is one per node. Hermes must observe real volume and replica
outcomes, use supported version-matched procedures and avoid unsafe downgrades.
See [Longhorn upgrade](longhorn-upgrade.md).

Hermes monitors the cluster overnight and sends one Finnish Matrix report at
07:00. Hermes does **not** perform routine Renovate merges. Its runtime and
native jobs use the [Hermes operations sources](https://github.com/AgenticHomelab/oci-control-server/blob/main/docs/hermes-operations-source.md).
The retired custom runner,
merger and lifecycle tools remain disabled. The GitHub Actions workflow does
not touch OKE or any OCI host or cluster credentials.

## Manual exception and incident response

Talos/Kubernetes version PRs, non-Renovate changes, and unsupported upgrade
paths remain separately reviewed. A specifically authorized operator or agent
may repair failed deployments through the existing GitOps and incident process.
Preserve backup and recovery requirements for stateful changes. An Actions
merge is not an endorsement of untested compatibility or a completed rollout.
