# Flux Operator ownership and future upgrade gates

Status: **current GitOps ownership reconciled on 2026-10-12**.
The `flux-operator` reconciliation unit adopts the existing
`flux-system/flux-operator` Helm release (Operator `0.61.0`).
The cluster `FluxInstance` runs Flux distribution `2.9.6`.
`flux-web-ui` owns only the independent server-only `flux-web`
release (`0.61.0`). Neither unit owns the `flux-system` Namespace.

[Flux Operator self-management guidance](https://fluxoperator.dev/docs/guides/migration/#automating-flux-operator-upgrades).

## Ownership invariants

- Keep the existing `flux-operator` HelmRelease identity, namespace,
  service account, permissions and release state. Its registry resource has
  prune protection to prevent accidental control-plane uninstall.
- Pin the operator OCI chart version **and** digest; review them together.
  Preserve CRD ownership and use the configured chart CRD upgrade strategy.
- Only the `FluxInstance` selects the Flux controller distribution. The
  independent server-only web release does not satisfy operator compatibility.
- Normal Flux reconciliation follows approved Git merges. Never use manual
  Helm upgrades, destructive bootstrap or force reconciliation merely to
  bypass a failing PR gate.

## Recorded 2026-10-12 upgrade

The operator was upgraded from 0.48.0 to 0.61.0 and adopted into GitOps
before the Flux distribution moved from 2.8.6 to 2.9.6.
The pre-upgrade chart comparison found no removed/added operator resource
identities or RBAC rule changes. The distribution review examined removed
beta APIs, post-render behavior, stored CRD versions and GCR Receiver changes.
Post-reconciliation checks confirmed Flux controllers, FluxInstance, the
Git/SOPS source and dependent Kustomizations/HelmReleases healthy.

The installed 2.9 distribution supports Kubernetes 1.34–1.36:
[Flux 2.9 release](https://fluxcd.io/blog/2026/06/flux-v2.9.0/).
Kubernetes 1.37 remains blocked until supported platform combinations and
an approved new Flux version are actually available.

## For future operator or distribution upgrades

Prepare separate operator, Flux controller and (if relevant) web UI changes.
Before approval, compare current and target chart identities, CRDs and
`status.storedVersions`, RBAC, `FluxInstance` API compatibility, workload
readiness and Git source and ESO behavior. Check the official release interval, run
exact-head validation and review integration with current `main`. Use one
approved rollout at a time.

After a merge, require the expected controller image versions and CRDs,
healthy FluxInstance, ready child Kustomizations and HelmReleases, and
representative application availability. If a regression appears, stop the
change queue and propose a scoped forward fix or compatible rollback.
A Git revert does not restore upgraded CRD schemas, data or source state.
Never uninstall the operator or weaken the prune protection as recovery.
