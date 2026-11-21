#!/usr/bin/env bash
set -euo pipefail

namespace=authentik
production_cluster=authentik-postgres
restore_cluster=authentik-postgres-restore-test
mode=
evidence_dir=
approval=
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest_dir="$repo_root/kubernetes/infrastructure/authentik/restore-test"

usage() {
  cat <<'EOF'
Usage:
  cnpg-restore-test.sh --apply --evidence-dir PATH
  cnpg-restore-test.sh --verify --evidence-dir PATH
  cnpg-restore-test.sh --cleanup --approve-cleanup authentik-postgres-restore-test

The apply and cleanup modes mutate only the isolated restore-test resources.
Run them only after explicit operational approval. Verification is read-only
apart from PostgreSQL read-only transactions in the restored cluster.
EOF
}

while (($#)); do
  case "$1" in
    --apply) mode=apply; shift ;;
    --verify) mode=verify; shift ;;
    --cleanup) mode=cleanup; shift ;;
    --evidence-dir) evidence_dir="$2"; shift 2 ;;
    --approve-cleanup) approval="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "$mode" ]] || { usage >&2; exit 2; }
for command in kubectl jq date; do
  command -v "$command" >/dev/null 2>&1 || { echo "Missing required command: $command" >&2; exit 1; }
done

assert_production_untouched() {
  kubectl -n "$namespace" get cluster.postgresql.cnpg.io "$production_cluster" -o json |
    jq -e '.status.phase == "Cluster in healthy state" and .status.readyInstances == 3' >/dev/null
}

case "$mode" in
  apply)
    [[ -n "$evidence_dir" ]] || { echo "--evidence-dir is required for apply" >&2; exit 2; }
    assert_production_untouched
    if kubectl -n "$namespace" get cluster.postgresql.cnpg.io "$restore_cluster" >/dev/null 2>&1; then
      echo "Restore-test cluster already exists; refusing to replace it." >&2
      exit 1
    fi
    backup_json="$(kubectl -n "$namespace" get backups.postgresql.cnpg.io -o json)"
    backup_record="$(jq -c --arg cluster "$production_cluster" '[.items[] | select(.spec.cluster.name == $cluster and .status.phase == "completed" and ((.status.backupId // .status.backupID // "") != "")) | {id:(.status.backupId // .status.backupID), stopped:.status.stoppedAt}] | sort_by(.stopped) | last // empty' <<<"$backup_json")"
    backup_id="$(jq -r '.id // empty' <<<"$backup_record")"
    target_time="$(jq -r '.stopped // empty' <<<"$backup_record")"
    [[ "$backup_id" =~ ^[0-9T]+$ && -n "$target_time" ]] || { echo "No completed backup is available for a pinned restore." >&2; exit 1; }

    mkdir -p "$evidence_dir"
    requested_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq -n --arg cluster "$restore_cluster" --arg source "$production_cluster" --arg backupId "$backup_id" --arg backupCompletedAt "$target_time" --arg requestedAt "$requested_at" \
      '{restoreCluster:$cluster,sourceCluster:$source,backupId:$backupId,backupCompletedAt:$backupCompletedAt,requestedAt:$requestedAt,state:"requested"}' \
      >"$evidence_dir/cnpg-restore-evidence.json"

    kubectl patch --local -f "$manifest_dir/cluster.yaml" --type merge \
      -p "{\"spec\":{\"bootstrap\":{\"recovery\":{\"recoveryTarget\":{\"backupID\":\"$backup_id\"}}}}}" \
      -o yaml | kubectl apply -f -
    echo "Restore requested. Wait for completion, then run --verify."
    ;;
  verify)
    [[ -n "$evidence_dir" ]] || { echo "--evidence-dir is required for verification" >&2; exit 2; }
    assert_production_untouched
    restore_json="$(kubectl -n "$namespace" get cluster.postgresql.cnpg.io "$restore_cluster" -o json)"
    jq -e '.status.phase == "Cluster in healthy state" and .status.readyInstances == 1' <<<"$restore_json" >/dev/null

    primary="$(jq -r '.status.currentPrimary // empty' <<<"$restore_json")"
    [[ -n "$primary" && "$primary" == "$restore_cluster-"* ]] || {
      echo "Restore-test primary could not be identified safely." >&2
      exit 1
    }

    query_result="$(kubectl -n "$namespace" exec -i "$primary" -c postgres -- psql -XAt --set=ON_ERROR_STOP=1 -d authentik <<'SQL'
BEGIN READ ONLY;
SELECT current_database();
SELECT count(*) > 0 FROM pg_namespace WHERE nspname = 'public';
SELECT to_regclass('public.django_migrations') IS NOT NULL;
SELECT to_regclass('public.authentik_core_user') IS NOT NULL;
ROLLBACK;
SQL
)"
    expected=$'BEGIN\nauthentik\nt\nt\nt\nROLLBACK'
    [[ "$query_result" == "$expected" ]] || { echo "Representative read-only integrity checks failed." >&2; exit 1; }

    evidence_file="$evidence_dir/cnpg-restore-evidence.json"
    [[ -f "$evidence_file" ]] || { echo "Apply-time evidence is required for verification." >&2; exit 1; }
    backup_id="$(jq -r '.backupId // empty' "$evidence_file")"
    backup_completed_at="$(jq -r '.backupCompletedAt // empty' "$evidence_file")"
    [[ "$backup_id" =~ ^[0-9T]+$ && -n "$backup_completed_at" ]] || { echo "Apply-time backup evidence is invalid." >&2; exit 1; }

    restored_at="$(jq -r '[.status.conditions[]? | select(.type == "Ready" and .status == "True")] | last | .lastTransitionTime // empty' <<<"$restore_json")"
    [[ -n "$restored_at" ]] || { echo "CNPG recovery completion time is unavailable." >&2; exit 1; }
    created_at="$(jq -r '.metadata.creationTimestamp' <<<"$restore_json")"
    created_epoch="$(date -d "$created_at" +%s)"
    restored_epoch="$(date -d "$restored_at" +%s)"
    verified_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    jq \
      --arg startedAt "$created_at" \
      --arg completedAt "$restored_at" \
      --arg verifiedAt "$verified_at" \
      --argjson elapsedSeconds "$((restored_epoch - created_epoch))" \
      '. + {state:"verified",restoreStartedAt:$startedAt,restoreCompletedAt:$completedAt,verifiedAt:$verifiedAt,recoveryElapsedSeconds:$elapsedSeconds,checks:{clusterHealthy:true,databaseName:true,publicSchema:true,djangoMigrationsTable:true,authentikUserTable:true,productionHealthy:true}}' \
      "$evidence_file" >"$evidence_file.tmp"
    mv "$evidence_file.tmp" "$evidence_file"
    echo "PASS: isolated restore and representative read-only integrity checks succeeded."
    ;;
  cleanup)
    [[ "$approval" == "$restore_cluster" ]] || {
      echo "Cleanup requires --approve-cleanup $restore_cluster" >&2
      exit 2
    }
    assert_production_untouched
    kubectl -n "$namespace" delete cluster.postgresql.cnpg.io "$restore_cluster" --wait=true
    cleanup_complete=false
    for _ in $(seq 1 30); do
      if ! kubectl -n "$namespace" get pvc,pod,job -l "cnpg.io/cluster=$restore_cluster" -o name | grep -q .; then
        cleanup_complete=true
        break
      fi
      sleep 2
    done
    if [[ "$cleanup_complete" != true ]]; then
      echo "Cleanup incomplete: restore-test resources remain." >&2
      exit 1
    fi
    assert_production_untouched
    echo "PASS: restore-test cluster and owned runtime resources were removed."
    ;;
esac
