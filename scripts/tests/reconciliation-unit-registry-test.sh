#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/scripts"
cp -R "$repo_root/kubernetes" "$tmpdir/kubernetes"
cp "$repo_root/scripts/validate-reconciliation-unit-registry.sh" "$tmpdir/scripts/"
validator="$tmpdir/scripts/validate-reconciliation-unit-registry.sh"

# Private source paths need not exist in the public checkout. Do not manufacture
# a public config stub or pull private Git/credentials into this offline check.
bash "$validator"
controller="$tmpdir/kubernetes/infrastructure/external-secrets/ks.yaml"
yq -i '.spec.path = "./kubernetes/infrastructure/external-secrets/missing-public-app"' "$controller"
if bash "$validator" >"$tmpdir/result" 2>&1; then
  echo 'Registry must reject missing paths in its own public source.' >&2
  exit 1
fi
rg -q 'Flux Kustomization path does not exist' "$tmpdir/result"
yq -i '.spec.path = "./kubernetes/infrastructure/external-secrets/app"' "$controller"
yq -i '.spec.dependsOn = [{"name": "missing-prerequisite"}]' "$controller"
if bash "$validator" >"$tmpdir/result" 2>&1; then
  echo 'Registry must reject unregistered prerequisites, including private-source owners.' >&2
  exit 1
fi
rg -q 'Unregistered dependsOn target: missing-prerequisite' "$tmpdir/result"
echo 'PASS: source-aware registry paths retain public path and dependency rejection.'
