#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
helmrelease=kubernetes/infrastructure/flux-operator/app/helmrelease.yaml
source=kubernetes/infrastructure/flux-operator/app/ocirepository.yaml
# Adoption must reuse the installed release, storage and existing service account.
yq -e '.metadata.namespace == "flux-system" and .spec.releaseName == "flux-operator" and .spec.targetNamespace == "flux-system" and .spec.storageNamespace == "flux-system" and .spec.serviceAccountName == "flux-operator" and .spec.install.createNamespace == false and .spec.upgrade.crds == "CreateReplace" and .metadata.annotations."kustomize.toolkit.fluxcd.io/prune" == "disabled"' "$helmrelease" >/dev/null
# No floating target may bypass manual review; bind the chart to an OCI digest.
yq -e '(.spec.ref.digest | test("^sha256:[0-9a-f]{64}$"))' "$source" >/dev/null
render=$(kubectl kustomize kubernetes/infrastructure/flux-operator)
if printf '%s\n' "$render" | yq -e 'select(.kind == "Namespace")' >/dev/null 2>&1; then
  echo "Operator unit must not own the bootstrap namespace" >&2
  exit 1
fi
# The standalone web release must not become a second operator.
yq -e '.spec.values.web.serverOnly == true and .spec.values.installCRDs == false and .spec.releaseName == "flux-web"' kubernetes/infrastructure/flux-web-ui/app/helmrelease.yaml >/dev/null
echo "PASS: operator adoption preserves control-plane identity and namespace ownership."
