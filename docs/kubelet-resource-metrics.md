# Interim kubelet resource metrics

Implementation proposed from main `20e6ca20017405e9d4a2f21d81e075c1d6d86694`.
PR #322 merged as `778b711d2720f1defd20963321e396e21058e268`.
The operator reports production ingestion and projected-token refresh accepted
as of the 2026-10-16 task. This research session did not repeat those live checks;
local validation alone does not establish acceptance. The pre-merge procedure
below records the original rollout gates and applies to future collector changes,
not an instruction to repeat activation. Merging an Alloy configuration change
into active Flux normally replaces its singleton Pod; retain the drained-WAL gate.

The [2026-10-16 serving TLS research](kubelet-serving-tls-research-20261016.md)
records the remaining trust/lifecycle work without changing this scrape.

## Collection and ownership

The existing official Alloy chart 1.13.1 / Alloy v1.20.1 remains one StatefulSet
with the same ServiceAccount, 2 GiB Longhorn RWO WAL claim and 100m/128Mi requests,
500m/512Mi limits. No new runtime, sidecar, exporter, operator or Prometheus server.
Existing KSM/self scrapes and the entire OCI remote-write block are unchanged.

Native `discovery.kubernetes` role `node` watches Nodes using verified Kubernetes
API HTTPS and the mounted public root. `discovery.relabel` selects each InternalIP
on port 10250 (IPv6 bracketed), excludes nodes without InternalIP and uses Node
name for `instance` and `node`. No hardcoded inventory, hostname DNS dependency,
ExternalIP fallback or copied Node labels/annotations. New nodes are discovered
automatically; discovery does not imply their endpoint is reachable or authorized.

Job **`talos/kubelet-resource`** scrapes HTTPS **`/metrics/resource`** every 60s,
with 10s timeout, 4 MiB response-body and 5,000 sample limits per node, 12 labels,
128-byte label names and 256-byte values. Sample limits apply before the downstream
metric filter; exceeding limits fails the scrape rather than silently truncating.
The post-scrape native relabel allowlist keeps:

| Family | Meaning | Endpoint labels |
| --- | --- | --- |
| `node_cpu_usage_seconds_total` | Cumulative node CPU, core-seconds | none |
| `node_memory_working_set_bytes` | Node working set, bytes | none |
| `pod_cpu_usage_seconds_total` | Cumulative Pod CPU, core-seconds | namespace, pod |
| `pod_memory_working_set_bytes` | Pod working set, bytes | namespace, pod |
| `container_cpu_usage_seconds_total` | Cumulative container CPU, core-seconds | namespace, pod, container |
| `container_memory_working_set_bytes` | Container working set, bytes | namespace, pod, container |
| `resource_scrape_error` | Kubelet statistics collection error indicator | none |

These names/labels are verified against the [pinned Kubernetes v1.36.4 collector](https://github.com/kubernetes/kubernetes/blob/v1.36.4/pkg/kubelet/metrics/collectors/resource_metrics.go).
Availability on actual Talos endpoints remains a live acceptance gate. This is
the small kubelet CPU/memory endpoint, not the full `/metrics/cadvisor` catalog.
Underlying statistics can come from CRI/cAdvisor; no new cAdvisor workload runs.
Counters require `rate(...[5m])` to obtain CPU cores; memory is working set, not
requests, limits or total resident memory. Do not add node, Pod and container
values together as independent consumption totals.

Native `up`, scrape duration/sample counts and series-added health are also kept.
Only name/job/instance/node/namespace/pod/container labels survive this filter;
existing remote write adds `cluster="talos-home"`. No container IDs, images,
UIDs or arbitrary labels. Resource timestamps retain the native scrape default
`honor_timestamps=true`; inspect actual usage sample ages as well as `up`.

## Authentication and temporary server-trust exception

The chart's native RBAC overrides **both** broad default lists. Its generated
ClusterRole/Binding grants only core `nodes: list,watch` for discovery and
`nodes/metrics: get` for kubelets, to `alloy/alloy`. No nodes/proxy, nodes/stats,
Pods, Secrets, mutations, signer rights or administration. Discovery across Nodes
is intentional; it is not restricted to a hardcoded three-name resource list.
No extra per-consumer SA or persistent credential Secret is needed.

`automountServiceAccountToken: false` remains. A read-only projected volume at
`/etc/alloy/kubelet-api`, without subPath, contains a native short-lived token
(requested lifetime 3,600s; actual issuer lifetime can differ) and the namespace's
public `kube-root-ca.crt` ConfigMap. Omitted token audience selects the API server's
default, also expected by native kubelet TokenReview. Volume mode is decimal 288
(0440), accessible through existing fsGroup 473. Kubelet rotates the projection;
native file-based HTTP authentication reads updates. Live token-refresh acceptance
is required; never print a token or use a long-lived Secret token to fix a 401.
Alloy needs no permission to create TokenReviews or retrieve the ConfigMap via API;
kubelet materializes the projection.

**Only the kubelet scrape sets `tls_config.insecure_skip_verify=true`.** HTTPS
encrypts but does not authenticate that server. An active on-path attacker could
forge usage data and capture a token usable for the limited Node/metrics grants.
Redirects are disabled for kubelet and discovery. Kubernetes discovery verifies
its mounted CA/name normally. OCI remote-write keeps normal trusted CA/SNI
verification for `metrics.${BASE_DOMAIN}`, existing Basic Auth and password-file mount.
No certificate, machine setting, metrics-server option, network listener, host
network/PID/path, privilege or public Service is changed. Port 10250 stays private.

The [TLS lifecycle assessment](kubelet-serving-tls-design.md) remains the future
path: prove an unattended, maintained approval/renewal solution, real signer CA
and correct DNS/IP SANs before any machine change. Then mount the verified public
bundle and remove **only this kubelet exception** in a separate reviewed Flux PR.
Do not extend it to API discovery, OCI or other scrapes. Pending-CSR control-plane
risks are not resolved by this implementation, which does not enable bootstrap.

## Pre-merge gates and separately approved rollout

No production queries or mutation were performed for this implementation. Local
render/validation cannot prove kubelet token authorization, network reachability,
actual usage availability or successful OCI ingestion. No ingestion claim is made.

1. Obtain merge/rollout approval; inspect the exact head, green CI and current main.
   Existing Flux/Helm gates are active: merging is effectively deployment approval.
   Require healthy Alloy/KSM, egress, OCI receiver and Longhorn, free WAL capacity,
   and record StatefulSet/Pod/PVC/volume identities. Check that ClusterRole and
   ClusterRoleBinding `alloy` do not conflict with another owner's resources.
2. Observe current local Alloy pending/lag and stored timestamps across multiple
   scrape cycles. Require delivery healthy, buffered timestamps delivered and queue
   drained before merge. **Do not roll during transport errors/backlog.** The
   [known WAL restart filter](talos-metrics-reliability.md) can lose older pending
   samples even with a retained claim. Wait for recovery; do not tune/restart to
   force an empty queue. Plan one brief Alloy-only scrape gap, not seamless service.
3. After approved merge let normal Flux reconcile. No direct apply, Helm install,
   imperative restart or forced reconciliation. Require the same StatefulSet and
   PVC identity, healthy three-replica Longhorn volume, one Ready Alloy Pod, and
   existing KSM/self targets healthy. Confirm only the intended role/binding and
   projected volume metadata; never retrieve token/ingestion Secret values.
4. Inspect bounded Alloy target/debug metadata through the existing local
   port-forward UI, logs/events and metrics. Require exactly three current node
   targets, InternalIP:10250, stable node names, no discovery 403, kubelet 401/403,
   scrape-limit failures or repeated timeout. Scrape success is not proof of
   authenticated server identity under the temporary exception.
5. Query the existing VictoriaMetrics loopback API or Grafana datasource through
   the approved operator path, recording UTC observation times and sample ages:

   ```promql
   up{cluster="talos-home",job="talos/kubelet-resource"}
   resource_scrape_error{cluster="talos-home",job="talos/kubelet-resource"}
   time() - timestamp(node_memory_working_set_bytes{cluster="talos-home",job="talos/kubelet-resource"})
   rate(node_cpu_usage_seconds_total{cluster="talos-home",job="talos/kubelet-resource"}[5m])
   node_memory_working_set_bytes{cluster="talos-home",job="talos/kubelet-resource"}
   rate(pod_cpu_usage_seconds_total{cluster="talos-home",job="talos/kubelet-resource"}[5m])
   pod_memory_working_set_bytes{cluster="talos-home",job="talos/kubelet-resource"}
   rate(container_cpu_usage_seconds_total{cluster="talos-home",job="talos/kubelet-resource"}[5m])
   container_memory_working_set_bytes{cluster="talos-home",job="talos/kubelet-resource"}
   ```

   Require three `up=1`, internal collection error=0, all six usage families,
   advancing underlying timestamps normally <150s old, node working sets >0 and
   meaningful representative Pod/container labels/values. Idle CPU may validly be
   zero; missing data is not zero. Wait at least five minutes for rates and initial
   provider timestamp refresh; do not mask missing families or stale samples.
   Compare the three Nodes and representative namespaces/workloads with Kubernetes.
6. Verify existing `talos/kube-state-metrics`, `talos/alloy` and OCI `control/host`
   jobs remain up/fresh. Observe remote-write retry/failure/queue/lag, WAL space and
   Alloy CPU/memory against existing bounds. No persistent 400/401/403/413/429/5xx.
   Sample limits/budgets are initial bounds to verify, not load-test acceptance.
7. Keep the Pod running past a projected-token refresh and repeat stored-timestamp
   checks without reading the token. Verify projected-file metadata changes only
   if needed; do not assume exactly one-hour rotation. Under separate test approval
   use the actual SA identity via protected native tooling to verify Node discovery
   and metrics access and denial of Secret/proxy/unrelated kubelet endpoints.
   The previously misleading Omni impersonation check is not authorization proof.

After all of these checks, record evidence and propose the smallest OCI Grafana
usage-panel update as a **separate PR**. No OCI repository change is included here;
its current “usage unavailable” messaging remains until actual ingestion is proven.

## Failure and rollback

First diagnose a new target failure without altering working state/self scrapes,
credentials, node configuration or TLS scope. A 401/audience or 403 mismatch is a
precise blocker; do not widen RBAC or create another credential as an ad hoc fix.
A failed resource collection can have `up=1` and `resource_scrape_error=1`.

With separate approval, revert this collector change through Git and normal Flux:
remove the new components, projection and chart RBAC overrides (restore the prior
`rbac.create=false`), keeping state/self scrapes, remote-write, StatefulSet and PVC.
That revert replaces Alloy too; apply the same drained-writer gate first. If a
running collector must urgently stop, follow the existing reviewed GitOps
scale-to-zero procedure with reconciliation enabled and preserve the WAL/Secret.
Suspension alone does not stop a running collector. No PVC deletion, network or
receiver change, or unrelated restart is part of rollback.
