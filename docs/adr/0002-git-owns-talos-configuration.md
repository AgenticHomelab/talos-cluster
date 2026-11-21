# Keep Talos desired configuration in Git

The permanently private `AgenticHomelab/homelab-secrets/talos/` Git source owns noncredential Talos machine configuration; Omni alone applies it and manages machine lifecycle. The public-candidate GitOps source owns only Kubernetes desired state. Generated configuration, credentials and secrets remain outside Git, preserving auditability without exposing sensitive material.
