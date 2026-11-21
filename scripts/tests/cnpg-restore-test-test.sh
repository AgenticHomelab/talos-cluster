#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
manifest="$repo_root/kubernetes/infrastructure/authentik/restore-test/cluster.yaml"
runner="$repo_root/scripts/cnpg-restore-test.sh"

if grep -Eq '^[[:space:]]+plugins:' "$manifest"; then
  echo "restore test must not archive WAL into the production object store" >&2
  exit 1
fi

if "$runner" --cleanup >/dev/null 2>&1; then
  echo "cleanup without the exact approval token must fail" >&2
  exit 1
fi

echo "PASS: CNPG restore test keeps recovery isolated and cleanup explicit"
