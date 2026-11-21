#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

for command in flux git kubectl rg yq; do
  if ! command -v "$command" >/dev/null; then
    echo "Required command not found: $command" >&2
    exit 1
  fi
done

apps_render=$(mktemp)
flux_render=$(mktemp)
trap 'rm -f "$apps_render" "$flux_render"' EXIT

kubectl kustomize kubernetes >"$apps_render"
flux build kustomization apps \
  --path ./kubernetes \
  --kustomization-file ./kubernetes/clusters/talos-home/apps.yaml \
  --dry-run >"$flux_render"

registry=$(yq -r '.resources[]' kubernetes/kustomization.yaml)
mapfile -td' ' categories < <(printf 'applications infrastructure observability\n')
for index in "${!categories[@]}"; do
  categories["$index"]="${categories["$index"]//$'\n'/}"
done

unit_directories=$(
  for category in "${categories[@]}"; do
    find "kubernetes/$category" -mindepth 1 -maxdepth 1 -type d -printf "$category/%f\n"
  done | sort
)

category_directories=$(find kubernetes -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
expected_top_level=$(printf 'applications\nclusters\nflux\ninfrastructure\nobservability\n' | sort)
if [[ "$category_directories" != "$expected_top_level" ]]; then
  echo "kubernetes must contain exactly the three category directories plus clusters and flux" >&2
  diff -u <(printf '%s\n' "$expected_top_level") <(printf '%s\n' "$category_directories") || true
  exit 1
fi

if [[ "$registry" != "$unit_directories" ]]; then
  echo "Registry entries do not match unit directories" >&2
  diff -u <(printf '%s\n' "$unit_directories") <(printf '%s\n' "$registry") || true
  exit 1
fi

if [[ "$registry" != "$(printf '%s\n' "$registry" | sort)" ]]; then
  echo "Registry entries are not alphabetical" >&2
  exit 1
fi

rendered_kinds=$(yq -r '.kind' "$apps_render" | rg -v '^---$' | sort -u)
if [[ "$rendered_kinds" != $'Kustomization\nNamespace' ]]; then
  echo "Registry output contains unexpected resource kinds" >&2
  printf '%s\n' "$rendered_kinds" >&2
  exit 1
fi

if yq -r 'select(.kind == "Namespace") | .metadata.name' "$apps_render" | rg -Fx flux-system >/dev/null; then
  echo "Registry output must not own the flux-system Namespace" >&2
  exit 1
fi

while IFS= read -r path; do
  local_path=${path#./}
  if [[ ! -d "$local_path" ]]; then
    echo "Flux Kustomization path does not exist: $path" >&2
    exit 1
  fi
done < <(yq -r 'select(.apiVersion == "kustomize.toolkit.fluxcd.io/v1") | .spec.path' "$apps_render" | rg -v '^---$' | sort -u)

kustomization_names=$(yq -r 'select(.apiVersion == "kustomize.toolkit.fluxcd.io/v1") | .metadata.name' "$apps_render" | rg -v '^---$' | sort -u)
# Unit dependencies may target cluster-level Flux Kustomizations, too.
cluster_kustomization_names=$(yq -r '
  select(.apiVersion == "kustomize.toolkit.fluxcd.io/v1" and .kind == "Kustomization") |
  .metadata.name
' kubernetes/clusters/talos-home/*.yaml | rg -v '^---$' | sort -u)
known_dependency_names=$(printf '%s\n%s\n' "$kustomization_names" "$cluster_kustomization_names" | sort -u)
while IFS= read -r dependency; do
  if ! printf '%s\n' "$known_dependency_names" | rg -Fx "$dependency" >/dev/null; then
    echo "Unregistered dependsOn target: $dependency" >&2
    exit 1
  fi
done < <(yq -r 'select(.apiVersion == "kustomize.toolkit.fluxcd.io/v1") | .spec.dependsOn[]?.name' "$apps_render" | rg -v '^---$' | sort -u)

namespace_count=$(yq -r 'select(.kind == "Namespace") | .metadata.name' "$apps_render" | rg -v '^---$' | wc -l)
kustomization_count=$(printf '%s\n' "$kustomization_names" | wc -l)
registry_count=$(printf '%s\n' "$registry" | wc -l)

echo "Reconciliation Unit Registry validation passed: ${registry_count} units, ${namespace_count} Namespaces, ${kustomization_count} Flux Kustomizations"
