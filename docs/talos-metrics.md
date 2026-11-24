# Talos metrics to OCI

Flux manages the `alloy`, `kube-state-metrics` and `metrics-server`
units; `control-01` owns its authenticated, private Nginx/VictoriaMetrics
receiver. Use the **current** HelmRelease pins in
`kubernetes/observability/alloy/` and `kubernetes/observability/kube-state-metrics/`;
old rollout chart and server versions are not current state evidence.

## Data flow and security

Alloy scrapes its own health, selected KSM node/Pod/Deployment/
StatefulSet state, and scoped kubelet `/metrics/resource` usage
metrics. State metrics reflect declared requests/limits and object
conditions, not real CPU/memory use; the kubelet path supplies
usage. Scrapes are configured at 60-second intervals.

Alloy sends `cluster="talos-home"` over
`https://control-01.tailscale.svc.cluster.local/api/v1/write`.
Verify normal TLS against `metrics.${BASE_DOMAIN}`; keep redirects
disabled. Existing Tailscale egress and private receiver provide
the network boundary, not a new public metrics endpoint.

The `alloy` StatefulSet remains a singleton using a retained
Longhorn-backed 2 GiB RWO WAL claim at `/var/lib/alloy`.
Neither its default three Longhorn replicas nor the remote-write
WAL constitute an independent offsite backup. Do not delete the
claim or mutate the StatefulSet identity merely to restart a
collector.

RBAC is restricted to KSM state resources, separate Alloy
node discovery/`nodes/metrics` access, and exact namespaced
Pod-log rights for `metrics-server` and `kube-state-metrics`.
No Secret-read, cluster-wide arbitrary Pod log reader, kubelet
`nodes/proxy`, mutating privilege or custom exporter is required.
No public Service or ingress is part of the collector.

ESO-synchronized `alloy/talos-metrics-ingestion` contains only
`password`, mounted read-only at `/etc/alloy/remote-write` and
read by `password_file`. Its Basic Auth identity is
`talos-home` and must match the operator-selected OCI Vault
value and Nginx verifier. Retain independent OCI and bootstrap recovery
credentials outside Git. Coordinate sender/receiver
rotation instead of issuing a competing Secret or weakening TLS.

## Reliability and verification

Native Alloy remote-write WAL, retries and backoff do not
guarantee exactly-once telemetry. A long network outage, full
2 GiB PVC, failed send or restart can lose samples; an 8-hour
age ceiling is not an outage SLA. Some HTTP 4xx failures do
not retry. Inspect both current and delayed sample ages,
remote-write queue/WAL lag and PVC space before a collector
upgrade or after receiver recovery.

For an approved read-only inspection:

```bash
kubectl -n flux-system get kustomizations alloy kube-state-metrics metrics-server
kubectl -n alloy get statefulsets,pods,pvc,helmreleases
kubectl -n kube-state-metrics get deployments,pods,helmreleases
```

Check scoped RBAC, actual Flux/Helm Ready, desired/source revision,
live receiver authentication and the authenticated Grafana/VictoriaMetrics
queries. Do not claim successful ingestion from Pod readiness alone.
The kubelet serving TLS exception applies **only** to its approved
resource-scrape path; it is not a blanket opt-out for outbound TLS.

Before any approved configuration change, inspect image/chart version
compatibility, resource budgets, credential custody and buffered metrics;
run complete desired-state CI and recheck both host and Talos metrics
after the normal Flux rollout. Do not reset the collector WAL to
create an apparent green dashboard.

## Related operations

[Talos scoped logs](talos-logs.md) share Alloy's process but not its
remote-write authentication or WAL durability.
[Resource metrics](kubelet-resource-metrics.md) describes the
scoped kubelet API and its TLS exception.
The public OCI Ansible source owns the
[metrics receiver](https://github.com/AgenticHomelab/oci-control-server/blob/main/ansible/talos-metrics-receiver.yml)
and [host observability configuration](https://github.com/AgenticHomelab/oci-control-server/blob/main/ansible/observability.yml).
For the live host and receiver checks, see the
[private control-host runbook](https://github.com/AgenticHomelab/homelab-secrets/blob/main/operations/hermes/runbooks/control-host-recovery.md#read-only-host-acceptance).
