#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
guard="$repo_root/scripts/automation/authentik_cnpg_safety_guard.py"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

python3 - "$guard" "$tmpdir" <<'PY'
import importlib.util
import json
import math
import subprocess
import sys
from pathlib import Path

module_path=Path(sys.argv[1])
tmpdir=Path(sys.argv[2])
spec=importlib.util.spec_from_file_location('authentik_cnpg_safety_guard', module_path)
mod=importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)

GIB=1024**3
assert mod.quantity_bytes('30Gi') == 30*GIB
assert mod.quantity_bytes('512Mi') == 512*1024**2
assert mod.MAX_WAL_FRACTION == 0.50
assert mod.MAX_INACTIVE_SLOT_LAG_FRACTION == 0.10
assert mod.expected_slot('authentik-postgres-2') == '_cnpg_authentik_postgres_2'

metrics='''
# HELP cnpg_collector_pg_wal Total WAL
cnpg_collector_up 1
cnpg_collector_pg_wal{value="size"} 603979776
cnpg_collector_pg_wal_archive_status{value="ready"} 0
cnpg_pg_replication_slots_active{slot_name="_cnpg_authentik_postgres_1"} 1
cnpg_pg_replication_slots_pg_wal_lsn_diff{slot_name="_cnpg_authentik_postgres_1"} 0
'''
parsed=mod.metric_snapshot(metrics)
assert parsed['collector_up'] == 1
assert parsed['wal_bytes'] == 603979776
assert parsed['archive_ready'] == 0
assert parsed['slots'] == [{
    'name':'_cnpg_authentik_postgres_1','active':True,'lag_bytes':0.0
}]

def slot(name, active, lag):
    return {'name':name,'active':active,'lag_bytes':lag}

def instance(name, wal, slots):
    return {
        'name':name,
        'pvc_request_bytes':30*GIB,
        'pvc_capacity_bytes':30*GIB,
        'collector_up':1.0,
        'wal_bytes':wal,
        'archive_ready':0.0,
        'slots':slots,
    }

def base_snapshot():
    return {
        'namespace':'authentik',
        'cluster':'authentik-postgres',
        'phase':'Cluster in healthy state',
        'ready':True,
        'continuous_archiving':True,
        'instances_desired':3,
        'ready_instances':3,
        'current_primary':'authentik-postgres-2',
        'instances':[
            instance('authentik-postgres-1', 620756992, [
                slot('_cnpg_authentik_postgres_3', False, 15777600),
            ]),
            instance('authentik-postgres-2', 603979776, [
                slot('_cnpg_authentik_postgres_1', True, 0),
                slot('_cnpg_authentik_postgres_3', True, 0),
            ]),
            instance('authentik-postgres-3', 620756992, [
                slot('_cnpg_authentik_postgres_1', False, None),
            ]),
        ],
    }

healthy=base_snapshot()
out=mod.evaluate(healthy)
assert out['status']=='PASS', out
assert out['reasons']==[]

# Reproduce the post-incident unsafe residue: replica-3 still contains ~20.2 GiB
# of WAL and a stale local slot named for the current primary at ~20.15 GiB lag.
unsafe=base_snapshot()
unsafe['instances'][2]['wal_bytes']=21692940288
unsafe['instances'][2]['slots'].append(
    slot('_cnpg_authentik_postgres_2', False, 21638724720)
)
out=mod.evaluate(unsafe)
assert out['status']=='BLOCK'
codes={reason['code'] for reason in out['reasons']}
assert 'WAL_FRACTION_EXCEEDED' in codes
assert 'INACTIVE_HA_SLOT_LAG_EXCEEDED' in codes
assert 'STALE_PRIMARY_HA_SLOT' in codes

# A CNPG cluster that has lost an instance or collector evidence must fail closed.
degraded=base_snapshot()
degraded['ready_instances']=2
out=mod.evaluate(degraded)
assert out['status']=='BLOCK'
assert 'READY_INSTANCE_COUNT_MISMATCH' in {r['code'] for r in out['reasons']}

missing=base_snapshot()
missing['instances'][0]['wal_bytes']=None
out=mod.evaluate(missing)
assert out['status']=='BLOCK'
assert 'WAL_SIZE_UNAVAILABLE' in {r['code'] for r in out['reasons']}

# The command-line path returns 0 only for a safe snapshot and 2 for deterministic
# unsafe evidence. Collection uncertainty uses a distinct non-zero fail-closed path.
for label, snapshot, expected in [
    ('healthy', base_snapshot(), 0),
    ('unsafe', unsafe, 2),
]:
    path=tmpdir/f'{label}.json'
    path.write_text(json.dumps(snapshot), encoding='utf-8')
    completed=subprocess.run([sys.executable, str(module_path), '--snapshot', str(path)], capture_output=True, text=True)
    assert completed.returncode==expected, (label, completed.returncode, completed.stdout, completed.stderr)
    result=json.loads(completed.stdout)
    assert result['status']==('PASS' if expected==0 else 'BLOCK')

bad=tmpdir/'bad.json'
bad.write_text('{not-json\n', encoding='utf-8')
completed=subprocess.run([sys.executable, str(module_path), '--snapshot', str(bad)], capture_output=True, text=True)
assert completed.returncode==1
assert json.loads(completed.stdout)['status']=='BLOCK'

print('CNPG safety guard assertions passed')
PY

# The live collector is structurally read-only. A future mutation verb added to
# the guard is a contract violation even if a caller never exercises it in tests.
if rg -n '"(apply|patch|delete|replace|create|edit|exec|rollout|scale|drain|cordon|uncordon|reconcile)"' "$guard"; then
  echo "CNPG safety guard contains a forbidden mutation/exec verb" >&2
  exit 1
fi

echo 'PASS: Authentik CNPG safety guard blocks WAL/slot residue and remains read-only.'
