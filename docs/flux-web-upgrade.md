# Standalone Flux web 0.61.0: completed upgrade

Status: **DEPLOYED and VERIFIED on 2026-10-12**. The `flux-web-ui`
reconciliation unit owns the server-only `flux-web` Helm release at
Flux Operator chart `0.61.0`. The Flux controller installation is owned by
the separate GitOps-managed `flux-operator` release; both were 0.61.0 at
this upgrade. Inspect the current Git pins for subsequent updates.
This web deployment does not own CRDs or the `flux-system` Namespace.

## Historical review

The 0.48.0 -> 0.61.0 review examined the
[official release interval](https://github.com/controlplaneio-fluxcd/flux-operator/compare/v0.48.0...v0.61.0)
and the [standalone installation boundary](https://fluxoperator.dev/docs/web-ui/standalone-install/).
With the existing values, offline rendering showed only version labels
and the image changing. The reviewed web release preserved
`serverOnly: true`, `installCRDs: false`, release/namespace identity,
Service ports, NetworkPolicy, RBAC, service account, probes and authentication.
The approved post-merge checks showed the web Deployment/HelmRelease Ready,
with the separately managed controller distribution healthy.

## Future changes and verification

Inspect the current live HelmRelease, Deployment image, protected management
route, authentication and permitted inventory views before a new chart
upgrade. Pin and validate the full chart digest; require exact-head CI and
manual merge approval. After normal Flux reconciliation verify availability
and unchanged access policy. Do not test workload mutation controls as a
health probe or weaken authentication to recover a management UI.

If a web-only upgrade fails, stop the upgrade queue and review a compatible
version/digest revert. Do not uninstall Flux controllers or operator CRDs to
repair the web interface.
