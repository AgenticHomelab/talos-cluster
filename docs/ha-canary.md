# Historical HA Canary

The synthetic HA Canary was retired from active GitOps on 2026-10-03. It measured
stateless request continuity and separate Longhorn/NFS marker recovery paths;
it held no user data. Its workload and removed test machinery remain available
in Git history, not as supported current operational tools.

Keep the [private historical failure-test evidence](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/ha-reports/README.md). Reintroduction would need
a new reviewed GitOps change and operator-approved failure plan; it is not part
of routine health checking. See [historical testing boundaries](ha-failure-testing.md).
