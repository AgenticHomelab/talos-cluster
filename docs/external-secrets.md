# External Secrets Operator: foundation staging

## Current boundary

This is the **initial controller/store foundation for issue #15**, not a Secret
ownership cutover or a deployment acceptance report. The desired-state change
adds one standard reconciliation unit, `infrastructure/external-secrets`.
No live operations are part of this stage. **Keep this foundation unmerged**:
the existing private ConfigMap does not yet contain the required OCI inputs, and
OCI IAM/provider-access prerequisites still need operator action. The config
Kustomization is not suspended; merging it would request reconciliation, not
merely publish a plan. This staging change is not deploy-ready.

The existing **15 private SOPS Secret owners**, their decryption and consumer
prerequisites remain unchanged. The private Git source, deploy credential,
`homelab-private-config` and `homelab-private-vars` substitution remain in use.
There are no application `ExternalSecret` objects or provider credentials in
this public unit. Do not remove old owners, ciphertext, SOPS/bootstrap identities
or recovery material on the strength of controller/store readiness.

## Ownership and ordering

| Owner | Source and path | Readiness contract |
| --- | --- | --- |
| `external-secrets` | Public `flux-system`, `./kubernetes/infrastructure/external-secrets/app` | `wait: true`; HelmRelease installs the upstream controller, webhook, certificate controller and CRDs |
| `external-secrets-config` | Private `homelab-secrets`, `./kubernetes/infrastructure/external-secrets/config` | Depends on `external-secrets` and `homelab-private-config`; waits for `ClusterSecretStore/oci-vault` Ready |

The config owner substitutes from `flux-system/homelab-private-vars`. Its private
path is not mirrored by a public placeholder directory. Public registry checks
validate local paths only for the public GitRepository; private-source CI must
validate the private path and its rendered objects.

With Flux `wait: true`, health checks cover every resource in the private config
apply set; the explicit `healthChecks` target documents the required store. The
`healthCheckExprs` predicate is what requires the ESO `Ready=True` condition even
when all-resource waiting takes precedence over the target list. A missing
status/conditions or `Ready=False` does not pass. This proves a declared readiness
gate, not successful OCI authentication or secret value equivalence.

## Reviewed upstream input

- Official chart repository: `https://charts.external-secrets.io`.
- Chart `external-secrets` **2.15.0**, application image default **v2.15.0**.
- Official tag `helm-chart-2.15.0`, source commit
  `54d622f42d4b1b03900d49f8bda05f077d83f2fe`.
- Release package `external-secrets-2.15.0.tgz`, SHA-256
  `ed94d41cc67e392ea45e370345eb491b0fdc21387f1aaaefcf8e2e6c85089e1d`.
  The official chart index advertises the same digest. The checked package's
  values and values schema match the source tag. The package includes the
  generated CRD schemas, which are validated from that exact archive.

The package checksum lives in the unit's `upstream.sha256`. CI and the offline
complete gate check it before rendering. Updating the chart requires reviewing
and updating this checksum alongside the HelmRelease; a version bump alone
intentionally fails closed. Helm validates values against the package's
`values.schema.json`; the chart test also checks the served/storage v1 store
schema and Oracle `UserPrincipal` fields. This is offline validation, not API
admission or runtime provider acceptance.

The chart owns its CRDs; do not install a second vendored CRD bundle. Upstream
webhook/certificate management remains enabled. Pull-only delivery disables
`PushSecret`/`ClusterPushSecret` processing and their CRDs, and removes
ServiceAccount-token creation from controller RBAC because OCI `UserPrincipal`
does not need workload-token minting. Controller liveness/readiness probes are
explicitly enabled. Other upstream defaults are retained.

Primary references:

- [Exact upstream tag](https://github.com/external-secrets/external-secrets/tree/helm-chart-2.15.0)
- [Version-matched Oracle provider](https://github.com/external-secrets/external-secrets/blob/helm-chart-2.15.0/docs/provider/oracle-vault.md)
- [Flux health-check expressions](https://fluxcd.io/flux/components/kustomize/kustomizations/#health-check-expressions)

## Private-source prerequisite (separate change)

The private config must provide `external-secrets.io/v1`
`ClusterSecretStore/oci-vault` with `spec.provider.oracle` and explicit
`principalType: UserPrincipal`. The existing private ConfigMap must supply
`OCI_ESO_REGION`, `OCI_ESO_VAULT_OCID`, `OCI_ESO_USER_OCID` and
`OCI_ESO_TENANCY_OCID`; their actual values remain private and are currently
missing from that ConfigMap. The paired private store maps them to `region`,
`vault`, `auth.user` and `auth.tenancy` respectively. Its authentication selectors
reference `external-secrets/oci-vault-auth`, keys `privatekey` and `fingerprint`.
Upstream spells the signer selector **`auth.secretRef.privatekey`** (lowercase),
paired with `fingerprint`; both selectors must identify the bootstrap Secret and
its namespace explicitly for this cluster-scoped store. Do not use OKE workload
identity or infer that a Talos Pod inherits the OCI host's Instance Principal.

The bootstrap signer cannot be delivered through an `ExternalSecret` that
requires this same store. Before deployment, the paired private change must
establish the authorized signer custody/delivery, read-only OCI IAM scope,
private config path, namespace and dependencies. This public config owner does
not introduce a new SOPS-decrypting Secret owner. Any separately managed signer
prerequisite must be explicit; do not assume readiness creates credentials.
No bootstrap credential is inspected or generated by public tests.

The pinned provider reads explicit remote keys with `GetSecretBundleByName`
(`SECRET_BUNDLE_READ`) and validates the store with `GetVault`. Do not add
secret-metadata/list grants solely to satisfy an unrelated diagnostic: those
are not required by the planned explicit-key delivery path. Effective scoped
IAM for the ESO user and successful provider access still need operator
verification; no local schema test establishes those permissions.

## Offline checks

Use the dependency acquisition and complete gate in [testing](testing.md), with
all five exact chart archives. No kubeconfig, private checkout or Secret values
are needed. The targeted foundation test is independently runnable:

```sh
bash scripts/tests/external-secrets-foundation-test.sh
bash scripts/tests/reconciliation-unit-registry-test.sh
bash scripts/tests/external-secrets-chart-input-test.sh
HELM_KUBERNETES_VERSION=v1.37.2 \
  HELM_CHARTS_DIR=/path/to/verified/chart-archives \
  ./scripts/validate-complete-desired-state.sh
git diff --check
```

The complete gate passes its one exact-chart render to
`external-secrets-chart-test.sh`. Negative checks reject a missing/corrupted ESO
archive before any chart rendering, a missing public-source path and an unknown
Flux prerequisite. No SOPS-removal assertions are introduced during staging.

## Gates still open

1. Review the paired private-source config/bootstrap change and both exact-head
   offline CI results; approve deployment separately. Merely registering these
   unsuspended units means a future merged source can reconcile them; this file
   does not authorize a merge or live reconciliation.
2. In an authorized deployment, establish controller/CRD/webhook readiness and
   independently verify the private store's OCI authentication, IAM scope and
   provider access without printing Secret content.
3. Before any later ownership handover, verify the complete active Secret
   inventory, source/version mapping, value equivalence and functional consumers.
   Apply the existing [ownership-transfer safeguards](gitops.md#sops-and-storage-boundaries)
   before removing an old writer. This foundation does not perform that handover.
4. Cleanup, SOPS retirement, rollback/recovery acceptance and claims of completed
   migration remain separate, unperformed stages. Controller Ready, store Ready,
   delivered Secret equality and application acceptance are different evidence.
