# Desired-state test-suite audit

The complete historical audit of test-suite coverage, local operator checkout
paths, baseline commands and individual synthetic probes is retained in the
[private test-suite audit](https://github.com/AgenticHomelab/homelab-secrets/blob/main/docs/test-suite-audit.md).

The current GitOps offline test contract, required pinned tools and meaningful
pass/fail boundaries are documented in [testing](testing.md). Its CI validates
manifests, Flux ownership, ingress boundaries, read-only policy fixture
contracts, Kustomize renders and repository safety without production access.
The separate private-source CI validates actual HA policy, Omni templates and
native recovery checker tests. No historical report establishes current live
runtime readiness or a successful restore.
