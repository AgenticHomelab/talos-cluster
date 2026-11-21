# Historical Kubernetes node failure testing

The HA Canary workload was retired on 2026-10-03. The Canary-specific observer,
probe summarizer, budget checker and their tests were removed in the 2026-10-17
test-suite cleanup. They had no active GitOps or recovery consumer. Do not use
old commands from history against the current cluster.

Preserved [private HA reports](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/ha-reports/README.md) describe the exercises actually performed;
they do not certify current availability. Future failure drills require a new,
operator-approved plan and current workload/backup evidence. Use
[maintenance](maintenance.md), [availability policy](high-availability.md) and
[node rejoin checks](../scripts/node-rejoin-network-check.sh) where applicable; none grants
permission to run a live test. Steady-state validation cannot prove recovery time.
