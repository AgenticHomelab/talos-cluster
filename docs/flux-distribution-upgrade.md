# Flux 2.9.6 distribution: completed upgrade and next-change gates

Status: **DEPLOYED and VERIFIED on 2026-10-12**.
Flux distribution is pinned to `2.9.6` in the Git-tracked `FluxInstance`.
Flux Operator `0.61.0` owns the controller installation through an adopted,
GitOps-managed Helm release. Kubernetes remains on the supported 1.36 minor;
Kubernetes 1.37 must be reviewed against a later compatible Flux release.

The former blocker ("Flux Operator 0.48.0 must be upgraded before Flux 2.9")
was resolved. The standalone `flux-web` server-only release is independently
at `0.61.0`; it is not the controller installation.

## Historical compatibility evidence

The 2.8.6 -> 2.9.6 review checked removed image and notification
`v1beta2` APIs, stored CRD versions, GCR Receiver secret fields and Helm
post-renderer strategy changes. Existing controller and CRD identities were
preserved; optional upstream controller components were not enabled.
The operator performed supported CRD migration as part of the approved
reconciliation. The recorded post-upgrade observations showed the expected
controller images, Git/SOPS reconciliation, ready dependent releases and
no ownership transfer or availability regression.

See the [Flux 2.9.6 release](https://github.com/fluxcd/flux2/releases/tag/v2.9.6),
[full compare](https://github.com/fluxcd/flux2/compare/v2.8.6...v2.9.6)
and [upgrade guidance](https://fluxcd.io/flux/installation/upgrade/).

## Future distribution changes

Before a **new** Flux version PR:

1. Confirm the current `FluxInstance` and operator HelmRelease, installed
   versions, controller Deployments, CRD served/storage versions, Git source,
   ESO synchronization and application health.
2. Check Kubernetes support for the **new** version and review its complete
   changelog, CRD/API migrations, storage and ownership implications.
3. Require exact-head CI, current-`main` integration and explicit operator
   merge approval. Never reinstall/bootstrap over a live Flux installation.
4. Let normal Flux reconciliation handle the merged change; check controller
   and workload readiness, source revision, ExternalSecret-consuming resources and
   representative services afterwards.
5. Treat rollback as a distinct reviewed decision. Reverting a version
   selector does not revert migrated CRD storage or data.

No Flux distribution change is authorized by this documentation update.
