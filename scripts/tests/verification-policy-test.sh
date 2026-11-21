#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate-verification-policy.sh"
policy="${HOMELAB_VERIFICATION_POLICY_FILE:-$repo_root/docs/verification-policy.yaml}"
"$validator"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
for change in \
  '.spec.mutationEnabled = true' \
  '.spec.verification.source.namespace = "other"' \
  '.spec.verification.applications[0].pathPrefix = "../escape/"' \
  '.spec.verification.applications[0].pathPrefix = "kubernetes/applications/aiostreams/../vaultwarden/"' \
  '.spec.verification.applications[0].services = ["unknown"]' \
  '.spec.verification.applications += [.spec.verification.applications[0]]' \
  '.spec.verification.pollSeconds = 0' \
  '.spec.verification.applications[0].helmReleases = ["unqualified"]'; do
  yq "$change" "$policy" >"$tmpdir/policy.yaml"
  if "$validator" --policy "$tmpdir/policy.yaml" >/dev/null 2>&1; then
    echo "invalid verification policy accepted: $change" >&2
    exit 1
  fi
done
echo "PASS: verification policy rejects mutation fields, unsafe targets and invalid probes"
