# Desired-state validation and test tiers

The `Validate desired state / desired-state` check runs the complete offline
gate for all non-Markdown PRs targeting `main`, including Renovate-authored
updates, and on manual workflow dispatch. It uses `contents: read`, no persisted
Git credentials and no production secrets. The existing nightly Renovate merger
must respect GitHub's required checks; a skipped, pending or failed check is not
successful validation. Non-Renovate merges remain manual unless separately
authorized. GitOps resources are not applied during testing.

## Prepare upstream dependencies, then run offline

Required: Bash, Python 3 standard library, Git, jq, Mike Farah yq, ripgrep,
Helm, kubectl (local Kustomize only), Flux CLI, plus envsubst and standard Linux utilities. CI pins downloaded
binaries and checks their SHA-256 sums. No Python framework or packages are
required. Use a clean checkout and an empty HOME without kubeconfigs or keys.

Download the four exact chart versions declared by Git first:

```sh
chart_dir=$(mktemp -d)
for entry in "infrastructure traefik" "infrastructure truenas-csi" "observability alloy" "observability kube-state-metrics"; do
  read -r unit_category unit <<<"$entry"
  version=$(yq -r '.spec.chart.spec.version' "kubernetes/$unit_category/$unit/app/helmrelease.yaml")
  repository=$(yq -r '.spec.url' "kubernetes/$unit_category/$unit/app/helmrepository.yaml")
  helm pull "$unit" --repo "$repository" --version "$version" --destination "$chart_dir"
done
HELM_KUBERNETES_VERSION=v1.37.2 HELM_CHARTS_DIR="$chart_dir" ./scripts/validate-complete-desired-state.sh
rm -r "$chart_dir"
```

Chart acquisition needs network access to upstream repositories. The gate itself
uses only those local archives: `helm template` receives the actual Git values,
release/namespace and the CI-pinned Kubernetes compatibility fixture. This
fixture is a rendering target, not an authority for Talos/Kubernetes upgrades. Missing archives, missing
renders or tool errors fail; chart security checks are no longer opt-in. No
Secret is decrypted. Archive versions come from the manifests, so a Renovate
upgrade does not require editing duplicate version assertions.

The gate runs all retained `scripts/tests/*-test.sh` programs and standard
`unittest discover` for `test_*.py`. It also validates registry/Flux dependencies,
service audiences, Matrix identity/auth and all Kustomize paths (including inactive recovery inputs), YAML and Secret/generated
file boundaries. Kustomize rendering is performed once per discovered path;
the registry validator owns hierarchy/dependency checks. Targeted semantic tests
render only where they need the resulting objects.

Repository whitespace validation compares the entire tracked working tree with
Git's empty tree, checks the index, and inspects untracked files. It catches
whitespace defects already committed in a clean PR checkout. Three pre-existing
whitespace-only manifest defects were removed to establish this stronger gate;
their rendered desired state is unchanged.

## What remains protected

Keep tests for plausible failures: read-only RBAC/group binding; ingress plane
separation and exact public VIP/ports; scoped Alloy/KSM/log RBAC and mounted
credentials; verified remote-write/log TLS boundaries; SOPS envelopes;
CNPG recovery write/cleanup safety and recovery write/cleanup approval; network-policy
error classification and bounded cleanup; revision-bound post-merge evidence;
manual merges; and Vaultwarden schema-aware failure
handling. [The audit](test-suite-audit.md) records every retention/deletion decision
and realistic negative/mutation evidence.

No test count certifies cluster health. Static policy checks do not prove effective
additive RBAC, CNI enforcement, chart runtime behavior, authentication, successful
backups or independent recovery. Mocks feed only synthetic command/API responses;
they do not exercise real cluster admission or OCI.

## Separate operational acceptance

Talos/Omni source rendering, machine identity injection checks, **real** HA and
verification policies, CNPG backup freshness and their adversarial tests belong
to the [private source CI](https://github.com/AgenticHomelab/homelab-secrets/blob/main/.github/workflows/validate.yml).
Read-only live Omni drift requires a separate authorized operator action
using the [private Talos runbook](https://github.com/AgenticHomelab/homelab-secrets/blob/main/talos/README.md).
Neither repository CI receives live cluster credentials.

CNPG recovery templates, restore runner, node rejoin and network-policy probes
remain operator-directed capabilities. Their offline tests use disposable files
and fake clients; live execution and recovery drills need their own plan and
approval. Preserve private recovery identities and off-host evidence.

The retired Canary runner/summarizer/budget checker, unsupported Hermes watchdog,
and one-off fixed-version Alloy WAL/CSR experiments are removed. Their dated
research and HA reports remain historical evidence. Repeating a research result
requires a new scoped experiment; CI must not report reproducing a known defect
as a production safety pass. OCI security-watch wrappers/recovery custody remain
under the separate control-server repository; this cleanup neither changes host
jobs nor retires their remaining source dependencies.

## Public CI policy fixtures

Public CI uses synthetic domains. In a private audit, supply the configured
base domain through `HOMELAB_AUDIT_BASE_DOMAIN` to the native
`scripts/tests/private-domain-bulk-test.sh` check. Keep the value out of
commands recorded in logs and out of Git.

The public GitOps CI uses `scripts/tests/fixtures/*-policy.yaml` containing
synthetic hostnames rather than private service addresses. The native validators
and post-merge verification contract remain exercised, but the actual operator
policy files are validated independently by private-source CI. The public
fixtures must never be used for live recovery or reachability decisions.

Live verifier entrypoints require the private source policy paths via their
existing `--policy` / `--availability-policy` arguments or the corresponding
`HOMELAB_VERIFICATION_POLICY_FILE` /
`HOMELAB_AVAILABILITY_POLICY_FILE` environment variables. Missing real policies
fail closed. CI explicitly forces only its synthetic test fixtures.
