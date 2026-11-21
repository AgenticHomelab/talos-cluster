# Shared app-template 5.3.0 upgrade and verification

Status: **COMPLETED on 2026-10-12**. Historical review and repeatable
verification steps are kept below; do not treat merged PR #276 as an open
deployment request.

## Completed change

The shared `flux-system/bjw-s-app-template` OCIRepository was upgraded from
bjw-s `app-template` 5.0.1 to 5.3.0 in
[PR #276](https://github.com/antief/talos-homelab/pull/276)
(squash SHA `7e2f51ca4d9668b2ea0ee104c6db83c491b3ea22`).
Documentation [PR #288](https://github.com/antief/talos-homelab/pull/288)
was subsequently merged as
`67ccdd7bab833b6c73fa7fddf523be42cfb643f1`.

The pinned source now uses digest
`sha256:0e13b145656490310ada364d8eb708e5f4f6384c7deb60d3f5f0fa56950ff63a`.
Live post-merge evidence confirmed all **12/12** HelmRelease consumers Ready
on the 5.3.0 chart, with 32/32 Flux Kustomizations, 3/3 nodes and
20/20 PVCs healthy at the review. Those numbers are a dated observation, not
a perpetual live-health guarantee. The offline chart comparison reported
only the `helm.sh/chart` metadata difference across 63 resources.

## Current shared consumers

| Namespace | HelmRelease |
| --- | --- |
| `aiostreams` | `aiostreams` |
| `borgwarehouse` | `borgwarehouse` |
| `cloudflare-ddns` | `cloudflare-ddns` |
| `ebooks` | `calibre-web-automated` |
| `matrix-element` | `matrix-element` |
| `matrix-signal` | `mautrix-signal` |
| `matrix-whatsapp` | `mautrix-whatsapp` |
| `matrix` | `matrix` |
| `mumble` | `mumble` |
| `valheim` | `valheim` |
| `valheim` | `valheim2` |
| `vaultwarden` | `vaultwarden` |

Read-only verification for a future audit:

```bash
CTX=omni-talos-home
kubectl --context "$CTX" -n flux-system get ocirepository bjw-s-app-template -o json |
  jq '{digest: .spec.ref.digest, revision: .status.artifact.revision,
       ready: ([.status.conditions[]? | select(.type == "Ready") | .status] | last)}'

kubectl --context "$CTX" get helmreleases -A -o json |
  jq -r '[.items[] |
    select(.spec.chartRef.kind == "OCIRepository" and
           .spec.chartRef.name == "bjw-s-app-template" and
           .spec.chartRef.namespace == "flux-system") |
    {ns: .metadata.namespace, name: .metadata.name,
     ready: ([.status.conditions[]? | select(.type == "Ready") | .status] | last),
     revision: .status.lastAttemptedRevision}] |
    sort_by(.ns, .name) |
    "count=\(length)",
    (.[] | "\(.ns)/\(.name)\tReady=\(.ready)\tRevision=\(.revision)")'
```

## Next upgrade procedure

For a new chart candidate, inspect the upstream release notes and full version
interval, compare chart rendering and resource identities against the **current**
source and values, review all 12 consumers, verify exact-head CI/current-base
integration and obtain manual merge approval. Then let Flux reconcile normally,
check each HelmRelease and representative application behavior, and record
the verified new digest/version here.

Never assume a metadata-only offline diff guarantees zero live reconciliation,
or that reverting a chart digest restores application or database state.

[app-template 5.3.0](https://github.com/bjw-s-labs/helm-charts/releases/tag/app-template-5.3.0)
· [Flux HelmRelease API](https://fluxcd.io/flux/components/helm/api/v2/)
