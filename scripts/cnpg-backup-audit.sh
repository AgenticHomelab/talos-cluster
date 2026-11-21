#!/usr/bin/env bash
set -euo pipefail

namespace=authentik
cluster=authentik-postgres
object_store=authentik-postgres-backups
max_age_seconds=93600
cluster_file=
object_store_file=
now_epoch="$(date +%s)"

while (($#)); do
  case "$1" in
    --namespace) namespace="$2"; shift 2 ;;
    --cluster) cluster="$2"; shift 2 ;;
    --object-store) object_store="$2"; shift 2 ;;
    --max-age-seconds) max_age_seconds="$2"; shift 2 ;;
    --cluster-file) cluster_file="$2"; shift 2 ;;
    --object-store-file) object_store_file="$2"; shift 2 ;;
    --now-epoch) now_epoch="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

for command in jq date; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

if [[ -n "$cluster_file" ]]; then
  cluster_json="$(<"$cluster_file")"
else
  command -v kubectl >/dev/null 2>&1 || {
    echo "Missing required command: kubectl" >&2
    exit 1
  }
  cluster_json="$(kubectl --request-timeout=15s -n "$namespace" get cluster.postgresql.cnpg.io "$cluster" -o json)"
fi

if [[ -n "$object_store_file" ]]; then
  object_store_json="$(<"$object_store_file")"
else
  object_store_json="$(kubectl --request-timeout=15s -n "$namespace" get objectstore.barmancloud.cnpg.io "$object_store" -o json)"
fi

wal_status="$(jq -r '[.status.conditions[]? | select(.type == "ContinuousArchiving")] | last | .status // "Missing"' <<<"$cluster_json")"
if [[ "$wal_status" != True ]]; then
  echo "FAIL: $namespace/$cluster continuous WAL archiving status is $wal_status" >&2
  exit 1
fi

last_backup="$(jq -r --arg cluster "$cluster" '.status.serverRecoveryWindow[$cluster].lastSuccessfulBackupTime // ""' <<<"$object_store_json")"
if [[ -z "$last_backup" ]]; then
  echo "FAIL: $namespace/$object_store has no successful base backup for $cluster" >&2
  exit 1
fi

backup_epoch="$(date -d "$last_backup" +%s 2>/dev/null || true)"
if [[ ! "$backup_epoch" =~ ^[0-9]+$ ]]; then
  echo "FAIL: $namespace/$object_store reports an invalid backup timestamp" >&2
  exit 1
fi

age_seconds=$((now_epoch - backup_epoch))
if ((age_seconds < 0 || age_seconds > max_age_seconds)); then
  echo "FAIL: latest successful $cluster base backup age is ${age_seconds}s; limit is ${max_age_seconds}s" >&2
  exit 1
fi

echo "PASS: $cluster WAL archiving is healthy and latest base backup age is ${age_seconds}s"
