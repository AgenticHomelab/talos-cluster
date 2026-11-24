#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/charts"
validator="$repo_root/scripts/validate-complete-desired-state.sh"
# Fail before any chart is templated. This must not recurse into the test gate.
printf 'not the reviewed upstream archive\n' > "$tmpdir/charts/external-secrets-2.15.0.tgz"
if HELM_CHARTS_DIR="$tmpdir/charts" HELM_KUBERNETES_VERSION=v1.37.2 \
  bash "$validator" >"$tmpdir/result" 2>&1; then
  echo 'An unverified ESO package must fail the complete gate.' >&2
  exit 1
fi
if ! rg -q 'external-secrets-2.15.0.tgz: FAILED' "$tmpdir/result"; then
  printf 'ESO archive was not rejected by its checksum before rendering:\n' >&2
  printf '%s\n' "$(<"$tmpdir/result")" >&2
  exit 1
fi
rm "$tmpdir/charts/external-secrets-2.15.0.tgz"
if HELM_CHARTS_DIR="$tmpdir/charts" HELM_KUBERNETES_VERSION=v1.37.2 \
  bash "$validator" >"$tmpdir/result" 2>&1; then
  echo 'A missing ESO package must fail the complete gate.' >&2
  exit 1
fi
rg -q 'Required chart missing: .*/external-secrets-2.15.0.tgz' "$tmpdir/result"
echo 'PASS: complete gate rejects corrupt and missing ESO input before rendering.'
