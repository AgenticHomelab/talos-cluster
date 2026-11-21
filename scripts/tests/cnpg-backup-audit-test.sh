#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
audit="$repo_root/scripts/cnpg-backup-audit.sh"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/cluster.json" <<'EOF'
{"status":{"conditions":[{"type":"ContinuousArchiving","status":"True"}]}}
EOF
cat >"$tmpdir/store.json" <<'EOF'
{"status":{"serverRecoveryWindow":{"authentik-postgres":{"lastSuccessfulBackupTime":"2026-07-15T00:00:00Z"}}}}
EOF

"$audit" --cluster-file "$tmpdir/cluster.json" --object-store-file "$tmpdir/store.json" --now-epoch 1784077200 >/dev/null

if "$audit" --cluster-file "$tmpdir/cluster.json" --object-store-file "$tmpdir/store.json" --now-epoch 1784268001 >/dev/null 2>&1; then
  echo "expected a backup older than 26 hours to fail" >&2
  exit 1
fi

cat >"$tmpdir/cluster.json" <<'EOF'
{"status":{"conditions":[{"type":"ContinuousArchiving","status":"False"}]}}
EOF
if "$audit" --cluster-file "$tmpdir/cluster.json" --object-store-file "$tmpdir/store.json" --now-epoch 1784077200 >/dev/null 2>&1; then
  echo "expected unhealthy WAL archiving to fail" >&2
  exit 1
fi

echo "PASS: CNPG backup audit enforces freshness and WAL health"
