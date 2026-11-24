#!/usr/bin/env bash
set -euo pipefail

# Match CI: imports in contract tests must not generate unpublished artifacts.
export PYTHONDONTWRITEBYTECODE=1

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
repository_check_root=

gates=(
  reconciliation-unit-registry
  service-audiences
  matrix-platform
  verification-policy
  availability-policy
  shell-tests
  yaml-and-kustomize
  plaintext-secrets
  generated-files
  git-diff
)

usage() {
  cat <<'EOF_USAGE'
Usage: validate-complete-desired-state.sh [--list-gates]
       validate-complete-desired-state.sh --check-repository PATH

Runs the complete Kubernetes GitOps desired-state release gate.
The separate private Talos/Omni source has its own exact-head validation and
read-only drift tooling. This command never mutates Kubernetes or Omni.
EOF_USAGE
}

while (($#)); do
  case "$1" in
    --omni-drift) echo 'Omni drift lives in the private homelab-secrets Talos source.' >&2; exit 2 ;;
    --list-gates) printf '%s\n' "${gates[@]}"; exit 0 ;;
    --check-repository) repository_check_root="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

check_repository_safety() {
  local root="$1" file
  local -a files untracked_files
  cd "$root"

  # Compare the entire tracked tree, including defects already committed in a PR.
  git diff --check "$(git hash-object -t tree /dev/null)"
  git diff --cached --check
  mapfile -t files < <(git ls-files --cached --others --exclude-standard)
  mapfile -t untracked_files < <(git ls-files --others --exclude-standard)

  for file in "${untracked_files[@]}"; do
    [[ -f "$file" ]] || continue
    if rg -n '[[:blank:]]+$' "$file" >/dev/null 2>&1; then
      echo "Untracked file contains trailing whitespace: $file" >&2
      return 1
    fi
  done

  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    if [[ "$file" =~ (^|/)(cluster-template\.rendered\.yaml|machines\.local\.env|secrets\.yaml|generated(/.*)?|talosconfig[^/]*|kubeconfig[^/]*|etcd-snapshot-.*\.db)$ ]]; then
      echo "Generated or local credential material is present: $file" >&2
      return 1
    fi
    if [[ "$file" == kubernetes/*.yaml || "$file" == kubernetes/**/*.yaml ]]; then
      if yq -e 'select(.kind == "Secret")' "$file" >/dev/null 2>&1 && [[ "$file" != *.sops.yaml ]]; then
        echo "Plaintext Kubernetes Secret manifest is not allowed: $file" >&2
        return 1
      fi
    fi
    if [[ "$file" == kubernetes/* && "$file" == *.sops.yaml ]] &&
      (! rg -q '^sops:$' "$file" || ! rg -q 'ENC\[AES256_GCM' "$file"); then
      echo "SOPS manifest is not encrypted: $file" >&2
      return 1
    fi
  done
}

if [[ -n "$repository_check_root" ]]; then
  for command in git rg yq; do
    command -v "$command" >/dev/null 2>&1 || { echo "Required command not found: $command" >&2; exit 1; }
  done
  check_repository_safety "$repository_check_root"
  echo "PASS: tracked and non-ignored unpublished repository files satisfy safety gates."
  exit 0
fi

cd "$repo_root"
# Public CI validates representative, non-production policy fixtures.
# The canonical private policies are checked by homelab-secrets exact-head CI.
export HOMELAB_AVAILABILITY_POLICY_FILE="$repo_root/scripts/tests/fixtures/availability-policy.yaml"
export HOMELAB_VERIFICATION_POLICY_FILE="$repo_root/scripts/tests/fixtures/verification-policy.yaml"
for command in bash flux git helm jq kubectl python3 rg yq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Required command not found: $command" >&2
    exit 1
  }
done

# Dependency acquisition is separate; validation must work without chart downloads.
: "${HELM_CHARTS_DIR:?Supply the directory of exact upstream chart archives (see docs/testing.md)}"
render_directory=$(mktemp -d)
trap 'rm -rf "$render_directory"' EXIT
kubernetes_version=${HELM_KUBERNETES_VERSION:?Set the Kubernetes compatibility target for offline Helm chart rendering}
helm_template_unit() {
  local unit="$1" release_dir="$2"
  local release="kubernetes/$release_dir/$unit/app/helmrelease.yaml"
  local version chart
  version=$(yq -r '.spec.chart.spec.version' "$release")
  chart="$HELM_CHARTS_DIR/$unit-$version.tgz"
  [[ -f "$chart" ]] || { echo "Required chart missing: $chart" >&2; exit 1; }
  if [[ "$unit" == external-secrets ]]; then
    (cd "$HELM_CHARTS_DIR" && sha256sum --check "$repo_root/kubernetes/infrastructure/external-secrets/upstream.sha256")
  fi
  yq '.spec.values' "$release" > "$render_directory/$unit-values.yaml"
  helm template "$unit" "$chart" --namespace "$unit" --kube-version "$kubernetes_version" \
    --values "$render_directory/$unit-values.yaml" > "$render_directory/$unit.yaml"
}
# Verify the new provider package before rendering any chart.
helm_template_unit external-secrets "infrastructure"
helm_template_unit traefik "infrastructure"
helm_template_unit truenas-csi "infrastructure"
helm_template_unit alloy "observability"
helm_template_unit kube-state-metrics "observability"

echo "=== Reconciliation Unit Registry ==="
./scripts/validate-reconciliation-unit-registry.sh

echo "=== Service Audiences ==="
./scripts/validate-service-audiences.sh

echo "=== Matrix Bridge Platform ==="
./scripts/validate-matrix-platform.sh

echo "=== Verification policy ==="
./scripts/validate-verification-policy.sh

echo "=== Availability policy ==="
./scripts/ha-audit.sh --policy-only

echo "=== Shell syntax and tests ==="
mapfile -t shell_files < <(rg --files scripts -g '*.sh' | sort)
for shell_file in "${shell_files[@]}"; do
  bash -n "$shell_file"
done
python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v
for test_file in scripts/tests/*-test.sh; do
  echo "=== Shell test: $test_file ==="
  case "$test_file" in
    */external-secrets-chart-test.sh) bash "$test_file" "$render_directory/external-secrets.yaml" ;;
    */truenas-csi-pilot-test.sh) bash "$test_file" "$render_directory/truenas-csi.yaml" ;;
    */public-ingress-boundary-test.sh) bash "$test_file" "$render_directory/traefik.yaml" ;;
    */talos-metrics-test.sh) bash "$test_file" "$render_directory/alloy.yaml" "$render_directory/kube-state-metrics.yaml" ;;
    */talos-logs-test.sh) bash "$test_file" "$render_directory/alloy.yaml" ;;
    *) bash "$test_file" ;;
  esac
done

echo "=== YAML and Kustomize ==="
mapfile -t yaml_files < <(rg --files -g '*.yaml' -g '*.yml' | sort)
yq eval-all 'true' "${yaml_files[@]}" >/dev/null
while IFS= read -r kustomization; do
  kubectl kustomize "${kustomization%/*}" >/dev/null
done < <(find kubernetes -type f -name kustomization.yaml | sort)

echo "=== Plaintext-secret safety ==="
echo "=== Generated-file and Git diff safety ==="
check_repository_safety "$repo_root"

echo "PASS: Kubernetes GitOps desired state is internally consistent and renderable; repository Secret envelopes and generated-file boundaries pass. Talos/Omni validation is owned by the private source."
