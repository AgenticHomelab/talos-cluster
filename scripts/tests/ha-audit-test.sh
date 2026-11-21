#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
audit="$repo_root/scripts/ha-audit.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cat >"$tmpdir/invalid-class.yaml" <<'EOF'
apiVersion: homelab.example/v1alpha1
kind: AvailabilityPolicy
services:
  - name: example
    class: magic
    recoveryBudgetSeconds: 5
    probe:
      type: https
      target: https://example.invalid/health
EOF

if "$audit" --policy "$tmpdir/invalid-class.yaml" --policy-only >"$tmpdir/stdout" 2>"$tmpdir/stderr"; then
  echo "expected an unknown availability class to fail validation" >&2
  exit 1
fi

grep -Fq "unsupported class 'magic' for service 'example'" "$tmpdir/stderr"

echo "PASS: availability policy rejects unknown service classes"

cat >"$tmpdir/incomplete-seamless.yaml" <<'EOF'
apiVersion: homelab.example/v1alpha1
kind: AvailabilityPolicy
services:
  - name: example
    class: seamless
    recoveryBudgetSeconds: 5
    probe:
      type: https
      target: https://example.invalid/health
EOF

if "$audit" --policy "$tmpdir/incomplete-seamless.yaml" --policy-only >"$tmpdir/stdout" 2>"$tmpdir/stderr"; then
  echo "expected an incomplete seamless service to fail validation" >&2
  exit 1
fi

grep -Fq "seamless service 'example' must declare a supported replicated workload and deployment PDB" "$tmpdir/stderr"

echo "PASS: seamless services require an auditable replicated workload"

cat >"$tmpdir/invalid-kind.yaml" <<'EOF'
apiVersion: homelab.example/v1alpha1
kind: AvailabilityPolicy
services:
  - name: example
    class: management
    recoveryBudgetSeconds: 300
    workload:
      kind: statefulset
      namespace: example
      name: example
    probe:
      type: workload
      target: example/example
EOF

if "$audit" --policy "$tmpdir/invalid-kind.yaml" --policy-only >"$tmpdir/stdout" 2>"$tmpdir/stderr"; then
  echo "expected an unsupported workload kind to fail validation" >&2
  exit 1
fi

grep -Fq "unsupported workload kind 'statefulset' for service 'example'" "$tmpdir/stderr"

echo "PASS: availability policy rejects unsupported workload kinds"

# Exercise the real audit with an entirely synthetic kubectl. Missing container
# status must not contribute to the distinct-node readiness count.
# Freeze backup timestamps before the audit captures its current time. Generating
# them during API reads can otherwise cross a second and look like future backups.
export HA_AUDIT_FIXTURE_EPOCH="$(date +%s)"
mkdir "$tmpdir/bin"
cat > "$tmpdir/bin/kubectl" <<'PY'
#!/usr/bin/env python3
import datetime
import json
import os
import sys
args = ' '.join(sys.argv[1:])
ready = {'type': 'Ready', 'status': 'True'}
cluster = {'spec': {'instances': 3}, 'status': {'readyInstances': 3,
    'phase': 'Cluster in healthy state', 'conditions': [{'type': 'ContinuousArchiving', 'status': 'True'}]}}
if 'api-resources' in args:
    print('clusters.postgresql.cnpg.io')
    sys.exit(0)
if 'get nodes ' in args:
    data = {'items': [{'metadata': {'name': str(n)}, 'status': {'conditions': [ready]}} for n in range(3)]}
elif 'get daemonset ' in args:
    data = {'spec': {'selector': {'matchLabels': {'app': 'fixture'}}},
            'status': {'desiredNumberScheduled': 3, 'numberReady': 3}}
elif 'get pods ' in args:
    status = {'phase': 'Running', 'conditions': [ready], 'containerStatuses': [{'ready': True}]}
    if os.environ.get('POD_STATUS') == 'missing':
        del status['containerStatuses']
    if os.environ.get('POD_STATUS') == 'unready':
        status['containerStatuses'][0]['ready'] = False
    data = {'items': [{'spec': {'nodeName': str(n)}, 'status': status} for n in range(3)]}
elif 'get clusters.postgresql.cnpg.io' in args:
    data = {'items': [cluster]}
elif 'get cluster.postgresql.cnpg.io' in args:
    data = cluster
    if '-n matrix ' in args and os.environ.get('MATRIX_BACKUP') == 'archive-failed':
        data['status']['conditions'][0]['status'] = 'False'
elif 'get objectstore.' in args:
    name = 'matrix-postgres' if '-n matrix ' in args else 'authentik-postgres'
    timestamp = datetime.datetime.fromtimestamp(
        int(os.environ['HA_AUDIT_FIXTURE_EPOCH']), datetime.timezone.utc)
    if name == 'matrix-postgres' and os.environ.get('MATRIX_BACKUP') == 'stale':
        timestamp -= datetime.timedelta(hours=27)
    data = {'status': {'serverRecoveryWindow': {name: {
        'lastSuccessfulBackupTime': timestamp.isoformat()}}}}
elif 'get nodes.longhorn.io' in args:
    data = {'items': [{'spec': {'allowScheduling': True}, 'status': {'conditions': [ready]}} for n in range(3)]}
elif 'get storageclass longhorn ' in args:
    data = {'parameters': {'numberOfReplicas': '3'}}
else:
    # Unused report tables/empty volume inventory; never contact a real client.
    data = {'items': []}
print(json.dumps(data))
PY
chmod +x "$tmpdir/bin/kubectl"
cat > "$tmpdir/ready-policy.yaml" <<'YAML'
services:
  - name: fixture
    class: seamless
    recoveryBudgetSeconds: 10
    workload: {kind: daemonset, namespace: fixture, name: fixture, minReplicas: 3}
    probe: {type: workload, target: fixture/fixture}
YAML
if ! PATH="$tmpdir/bin:$PATH" "$audit" --policy "$tmpdir/ready-policy.yaml" > "$tmpdir/audit.log"; then
  cat "$tmpdir/audit.log" >&2
  exit 1
fi
for status in missing unready; do
  if POD_STATUS="$status" PATH="$tmpdir/bin:$PATH" "$audit" --policy "$tmpdir/ready-policy.yaml" > "$tmpdir/audit.log" 2>&1; then
    echo "audit accepted $status container readiness" >&2
    exit 1
  fi
done
echo 'PASS: HA audit does not count missing or unready container statuses as ready nodes'

# Matrix can still serve /versions while MAS and database writes are broken.
# Healthy Authentik backups must not mask a Matrix archive/backup failure.
for failure in archive-failed stale; do
  if MATRIX_BACKUP="$failure" PATH="$tmpdir/bin:$PATH" "$audit" --policy "$tmpdir/ready-policy.yaml" > "$tmpdir/audit.log" 2>&1; then
    echo "audit accepted Matrix backup failure: $failure" >&2
    exit 1
  fi
done
echo 'PASS: HA audit rejects Matrix archive failures and stale backups independently of Authentik'
