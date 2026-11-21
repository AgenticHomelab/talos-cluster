# Use Omni for canonical Kubernetes API access

Operators access the target cluster's Kubernetes API through Omni instead of a Talos virtual IP. A direct kubeconfig targeting any healthy control-plane node is retained only for break-glass recovery, accepting that this fallback has no stable endpoint or single-node availability guarantee while avoiding a second primary access path to operate and test.
