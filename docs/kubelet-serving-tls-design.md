# Kubelet serving TLS: simplicity and lifecycle assessment

This design records kubelet serving TLS and native metric-collector trust requirements. No new CSR approver or machine configuration is authorized by this document.

The detailed machine addresses, service identities, historical records and
operational/recovery commands are kept in the [private owner document](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/kubelet-serving-tls-design.md).

For the current declarative Kubernetes desired state, inspect the owning
`kubernetes/` reconciliation unit and its offline validation.
