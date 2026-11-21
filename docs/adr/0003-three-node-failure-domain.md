# Target a three-node Talos control plane

The target cluster has three Talos control-plane nodes and is designed to tolerate the loss of one Kubernetes node. Platform services must preserve the shared cluster path across that failure, while workload-specific interruption budgets and external dependencies such as TrueNAS are documented separately.
