# Scoped Talos logs to control-01

Talos Alloy collects Pod logs from **only** the
`metrics-server` and `kube-state-metrics` namespaces. The
Talos/Flux unit owns the native Alloy components and RBAC;
the [control-01 receiver](https://github.com/antief/oci-control-server/blob/main/docs/talos-logs-receiver.md)
owns TLS, Basic Auth, Nginx and local Loki ingestion.

## Current collection boundary

Native Kubernetes API discovery lists/watches Pods in the
two named namespaces only; namespaced Roles grant `get,list,watch`
on `pods` and `get` on `pods/log`. Log streaming includes
Running Pod non-init containers, not former container instances,
host journals, deleted Pods or other application namespaces.
Do not grant cluster-wide Pod logs, `nodes/proxy`, Secrets,
exec or mutation permissions.

Alloy uses an explicitly projected short-lived Kubernetes token
and CA, not a static API token or broad ServiceAccount automount.
The same singleton Alloy StatefulSet, Longhorn claim and
native metric pipeline remain in place. No DaemonSet, hostPath,
custom runtime log shipper or new Pod ingress is necessary.

The writer sends to the exact private POST path

```text
https://control-01.tailscale.svc.cluster.local/loki/api/v1/push
```

with TLS `server_name="metrics.${BASE_DOMAIN}"`, standard CA
verification and no redirects. Authentication is the **separate**
SOPS-encrypted `alloy/talos-logs-ingestion` Secret, key
`password`, user `talos-logs` and mounted
`password_file`. It must match the selected OCI Vault v1
authority and protected Nginx verifier. Never reuse the
Talos metrics password; preserve independent age/private
recovery keys and coordinate any credential rotation.

The writer indexes a small label set: `cluster`, `job`,
`namespace`, `container`, `pod`; Loki may derive
`service_name`. Pod names rotate, and logs may contain sensitive
payload. No automatic secret redaction or per-namespace
Loki tenant isolation is guaranteed.

## Loss, capacity and acceptance

This feed is **best effort**, not an audit trail. Entries older
than one hour are filtered; 16-KiB messages and sustained rates
over the configured 5 lines/s (burst 10) can be dropped. Native
queue/batches have finite retries, the writer is memory-backed,
and Prometheus remote-write WAL does **not** protect Pod logs.
API replay after an Alloy restart can duplicate messages, while
source position advance, failed HTTP writes, Pod rotation or
long outages can lose them. Never claim gap-free retention.

The receiver limits wire bodies to 1 MiB and Loki uses native
seven-day retention subject to available disk. A successful
HTTP response or Loki `/ready` alone cannot certify both
Pod sources or indefinite retention.

**Evidence:** the initial two-namespace end-to-end acceptance
passed on 2026-10-17. Operator read-only control-01 checks on
2026-10-30 confirmed local Loki enabled/active/ready and at least
one recent log event from one of the selected namespaces.
That later check did **not** revalidate uninterrupted delivery
from both namespaces.

## Safe checks and recovery

```bash
kubectl -n flux-system get kustomizations alloy metrics-server kube-state-metrics
kubectl -n alloy get statefulsets,pods,pvc
```

Check the current Alloy ConfigMap, permitted namespace Roles,
live Pod log stream/error counters, writer send failures and
actual Loki indexed labels by each target namespace without
exporting raw log messages. In OCI check loopback Loki readiness,
disk/retention and the authenticated receiver's exact POST
behavior. Preserve the metric collector, NFS/Garage backups,
Tailnet receiver and private credential source throughout a
logging incident. Do not weaken TLS/auth, disable filters or
reset positions merely to make historical gaps disappear.

Log disable/rollback belongs to a reviewed Flux change affecting
only native logging components, namespaced RBAC and the dedicated
Secret; preserve all metrics components and WAL. OCI receiver
rollback is separate and must not silently break metrics.
See [Talos metrics](talos-metrics.md) and
[control Loki operations](https://github.com/antief/oci-control-server/blob/main/docs/control-loki.md).
