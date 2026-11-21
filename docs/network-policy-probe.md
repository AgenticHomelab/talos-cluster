# NetworkPolicy validation harness

The `network-policy-probe` namespace provides a standalone harness for
validating NetworkPolicy deny paths.

The namespace is separate from application namespaces so a temporary probe
Job represents traffic from an unapproved source namespace.

## Boundary

The namespace enforces the Kubernetes Pod Security Standards `restricted`
profile pinned to the cluster Kubernetes version.

Probe Jobs:

- use the repository-pinned BusyBox image;
- mount the probe script ConfigMap read-only;
- do not mount a ServiceAccount token;
- run as non-root;
- use `RuntimeDefault` seccomp;
- disable privilege escalation;
- drop all Linux capabilities;
- use a read-only root filesystem;
- have a bounded deadline and no retries; and
- exist only for the duration of a probe.

No persistent probe Job is part of desired state.

## Result classification

The probe first resolves the target Service DNS name and then performs a
bounded HTTP connection attempt.

A DNS failure fails the probe.

Any HTTP response means transport reached the destination and therefore
fails a deny-path test. A TCP connection refusal also fails because it
proves that the destination was reachable.

Only an explicitly recognized timeout or dropped connection is accepted as
the expected NetworkPolicy-denied result. Unknown transport failures fail
closed.

## Kubernetes permissions

The GitOps unit no longer installs Hermes-specific RBAC.

The invoking identity must independently have these namespaced permissions:

    batch/jobs:       create, get, list, watch, delete
    core/pods:        get, list, watch
    core/pods/log:    get

The generated probe Pod itself does not receive a Kubernetes API token.

## Invocation

Run the wrapper from an administrative environment with the required
permissions:

    ./scripts/network-policy-probe.sh \
      whoami.whoami.svc.cluster.local \
      80 \
      5

The wrapper creates a temporary Job, polls its status with bounded
Kubernetes API timeouts, prints its logs and performs best-effort
non-blocking cleanup.
