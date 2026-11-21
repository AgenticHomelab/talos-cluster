#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
yq -o=json '.' "$repo_root/kubernetes/applications/vaultwarden/app/helmrelease.yaml" | jq -e '
  .spec.upgrade.strategy.name == "RemediateOnFailure" and
  .spec.upgrade.remediation.retries == 0 and
  .spec.upgrade.remediation.remediateLastFailure == false and
  .spec.values.controllers.main.strategy == "Recreate" and
  .spec.values.persistence.data.retain == true and
  .spec.values.persistence.data.storageClass == "longhorn"
' >/dev/null
printf '%s\n' 'PASS: Vaultwarden failure stops without automatic schema-unaware remediation'
