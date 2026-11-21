# Matrix capacity and rollout gate

The Matrix Bridge Platform targets fewer than ten local users. Its initial
resource envelope is deliberately conservative and must be confirmed against
the Target Cluster before rollout:

| Workload | CPU request | Memory request | Memory limit |
| --- | ---: | ---: | ---: |
| Synapse | 250m | 512Mi | 2Gi |
| Matrix Authentication Service | 100m | 128Mi | 512Mi |
| Element Web | 25m | 32Mi | 128Mi |
| CloudNativePG instance, each of three | 100m | 256Mi | 1Gi |
| Each mautrix bridge | 100m | 128Mi | 512Mi |

These are scheduler inputs, not evidence of available capacity. Before an
approved rollout, use the Omni API Access Path to record the following
read-only evidence:

```bash
kubectl get nodes -o custom-columns='NAME:.metadata.name,CPU:.status.allocatable.cpu,MEMORY:.status.allocatable.memory'
kubectl top nodes
kubectl get pods -A -o json | jq '[.items[] | .spec.containers[] | .resources.requests // {}]'
```

The review must confirm that the platform fits after existing requests and
observed headroom, including while one node is unavailable. Live-cluster access
requires explicit permission; this document and the local validation gate do
not authorize running these commands.

Record the non-secret result in the implementation or rollout review using this
format, replacing generic node labels only in the private operator evidence:

| Evidence | Node A | Node B | Node C |
| --- | ---: | ---: | ---: |
| Allocatable CPU | | | |
| Allocatable memory | | | |
| Current requested CPU | | | |
| Current requested memory | | | |
| Observed peak CPU | | | |
| Observed peak memory | | | |

Also record the timestamp and observation window, the aggregate Matrix resource
requests, the remaining headroom with the busiest node removed, and a clear
`fit` or `does not fit` conclusion. Do not record credentials, workload
environment values or other secret material with the evidence.
