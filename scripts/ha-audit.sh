#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="${HOMELAB_AVAILABILITY_POLICY_FILE:-$repo_root/docs/availability-policy.yaml}"
policy_only=false

usage() {
  cat <<'EOF'
Usage: ./scripts/ha-audit.sh [--policy PATH] [--policy-only]

Validate the target cluster against its availability policy. Supply the private
policy using --policy or HOMELAB_AVAILABILITY_POLICY_FILE. With
--policy-only, validate the policy without accessing the live cluster.
EOF
}

while (($#)); do
  case "$1" in
    --policy)
      [[ $# -ge 2 ]] || {
        echo "--policy requires a path" >&2
        exit 2
      }
      policy="$2"
      shift 2
      ;;
    --policy-only)
      policy_only=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

validate_policy() {
  local duplicate_names incomplete_seamless invalid_class invalid_kind invalid_probe missing_fields

  [[ -f "$policy" ]] || {
    echo "availability policy not found: $policy" >&2
    return 1
  }

  duplicate_names="$(
    yq -r '.services[].name' "$policy" |
      sort |
      uniq -d
  )"
  if [[ -n "$duplicate_names" ]]; then
    echo "duplicate service names in availability policy: $duplicate_names" >&2
    return 1
  fi

  invalid_class="$(
    yq -r '
      .services[]
      | select(.class != "seamless" and .class != "bounded-recovery" and .class != "external-dependency" and .class != "management")
      | [.name, .class]
      | @tsv
    ' "$policy" | head -n 1
  )"
  if [[ -n "$invalid_class" ]]; then
    local service_name service_class
    IFS=$'\t' read -r service_name service_class <<<"$invalid_class"
    echo "unsupported class '$service_class' for service '$service_name'" >&2
    return 1
  fi

  missing_fields="$(
    yq -r '
      .services[]
      | select(
          (.name // "") == "" or
          (.class // "") == "" or
          (.recoveryBudgetSeconds | type) != "!!int" or
          (.probe.type // "") == "" or
          (.probe.target // "") == ""
        )
      | .name // "<unnamed>"
    ' "$policy" | head -n 1
  )"
  if [[ -n "$missing_fields" ]]; then
    echo "service '$missing_fields' is missing required policy fields" >&2
    return 1
  fi

  invalid_probe="$(
    yq -r '
      .services[]
      | select(.probe.type != "https" and .probe.type != "dns" and .probe.type != "workload" and .probe.type != "cnpg" and .probe.type != "tcp" and .probe.type != "udp")
      | [.name, .probe.type]
      | @tsv
    ' "$policy" | head -n 1
  )"
  if [[ -n "$invalid_probe" ]]; then
    local probe_service probe_type
    IFS=$'\t' read -r probe_service probe_type <<<"$invalid_probe"
    echo "unsupported probe type '$probe_type' for service '$probe_service'" >&2
    return 1
  fi

  invalid_kind="$(
    yq -r '
      .services[]
      | select(.workload != null)
      | select(.workload.kind != "deployment" and .workload.kind != "daemonset" and .workload.kind != "clusters.postgresql.cnpg.io")
      | [.name, .workload.kind]
      | @tsv
    ' "$policy" | head -n 1
  )"
  if [[ -n "$invalid_kind" ]]; then
    local kind_service workload_kind
    IFS=$'\t' read -r kind_service workload_kind <<<"$invalid_kind"
    echo "unsupported workload kind '$workload_kind' for service '$kind_service'" >&2
    return 1
  fi

  incomplete_seamless="$(
    yq -r '
      .services[]
      | select(.class == "seamless")
      | select(
          (.workload.kind // "") == "" or
          (.workload.namespace // "") == "" or
          (.workload.name // "") == "" or
          (.workload.minReplicas | type) != "!!int" or
          .workload.minReplicas < 2 or
          (.workload.kind == "deployment" and (.workload.pdb // "") == "") or
          (.workload.kind == "daemonset" and .workload.minReplicas < 3) or
          (.workload.kind != "deployment" and .workload.kind != "daemonset")
        )
      | .name
    ' "$policy" | head -n 1
  )"
  if [[ -n "$incomplete_seamless" ]]; then
    echo "seamless service '$incomplete_seamless' must declare a supported replicated workload and deployment PDB" >&2
    return 1
  fi
}

require yq
validate_policy

if [[ "$policy_only" == true ]]; then
  echo "PASS: availability policy is valid: $policy"
  exit 0
fi

require kubectl
require jq
require column

failures=0

printf '%s\n' '=== Kubernetes nodes ==='
kubectl get nodes -o wide

printf '\n%s\n' '=== Node health conditions that are not in the expected state ==='
unhealthy_nodes="$(kubectl get nodes -o json | jq -r '
  .items[] as $node
  | $node.status.conditions[]
  | select(
      (.type == "Ready" and .status != "True") or
      (.type != "Ready" and .status != "False")
    )
  | [$node.metadata.name, .type, .status, .reason, .message]
  | @tsv
')"
if [[ -n "$unhealthy_nodes" ]]; then
  column -t -s $'\t' <<<"$unhealthy_nodes"
  failures=$((failures + 1))
else
  echo 'PASS: all node health conditions are in the expected state.'
fi

node_inventory="$(kubectl get nodes -o json)"
node_count="$(jq '.items | length' <<<"$node_inventory")"
unschedulable_count="$(jq '[.items[] | select(.spec.unschedulable == true)] | length' <<<"$node_inventory")"
if ((node_count != 3 || unschedulable_count != 0)); then
  echo "FAIL: target cluster requires exactly three schedulable nodes; nodes=$node_count unschedulable=$unschedulable_count"
  failures=$((failures + 1))
else
  echo 'PASS: target cluster has exactly three schedulable nodes.'
fi

printf '\n%s\n' '=== Flux reconciliation health ==='
unready_flux="$(
  kubectl get \
    fluxinstances.fluxcd.controlplane.io,kustomizations.kustomize.toolkit.fluxcd.io,gitrepositories.source.toolkit.fluxcd.io,helmrepositories.source.toolkit.fluxcd.io,ocirepositories.source.toolkit.fluxcd.io,helmreleases.helm.toolkit.fluxcd.io \
    -A -o json |
    jq -r '
      .items[]
      | (.status.conditions // [] | map(select(.type == "Ready")) | first) as $ready
      | select($ready == null or $ready.status != "True")
      | [.kind, (.metadata.namespace // "<cluster>"), .metadata.name, ($ready.status // "Missing"), ($ready.message // "Ready condition missing")]
      | @tsv
    '
)"
if [[ -n "$unready_flux" ]]; then
  column -t -s $'\t' <<<"$unready_flux"
  failures=$((failures + 1))
else
  echo 'PASS: FluxInstance, sources, Kustomizations, and HelmReleases are Ready.'
fi

printf '\n%s\n' '=== Seamless Service policy ==='
while IFS=$'\t' read -r service kind namespace name minimum pdb; do
  [[ -n "$service" ]] || continue
  resource_json="$(kubectl -n "$namespace" get "$kind" "$name" -o json)"
  if [[ "$kind" == daemonset ]]; then
    desired="$(jq -r '.status.desiredNumberScheduled // 0' <<<"$resource_json")"
    ready="$(jq -r '.status.numberReady // 0' <<<"$resource_json")"
  else
    desired="$(jq -r '.spec.replicas // 1' <<<"$resource_json")"
    ready="$(jq -r '.status.readyReplicas // 0' <<<"$resource_json")"
  fi
  selector="$(
    jq -r '.spec.selector.matchLabels | to_entries | map("\(.key)=\(.value)") | join(",")' <<<"$resource_json"
  )"
  node_count="$(
    kubectl -n "$namespace" get pods -l "$selector" -o json |
      jq '[.items[] | select(.status.phase == "Running") | select((.status.containerStatuses | length) > 0) | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | select(all(.status.containerStatuses[]; .ready == true)) | select(.metadata.deletionTimestamp == null and (.spec.nodeName // "") != "") | .spec.nodeName] | unique | length'
  )"
  if [[ "$kind" == daemonset ]]; then
    hard_spread=true
    pdb_valid=true
  else
    hard_spread="$(jq -r '
      any(.spec.template.spec.topologySpreadConstraints[]?; .topologyKey == "kubernetes.io/hostname" and .whenUnsatisfiable == "DoNotSchedule") or
      any(.spec.template.spec.affinity.podAntiAffinity.requiredDuringSchedulingIgnoredDuringExecution[]?; .topologyKey == "kubernetes.io/hostname")
    ' <<<"$resource_json")"
    pdb_json="$(kubectl -n "$namespace" get poddisruptionbudget.policy "$pdb" -o json 2>/dev/null || true)"
    pdb_valid=false
    if [[ -n "$pdb_json" ]]; then
      pdb_valid="$(jq -n -r --argjson workload "$resource_json" --argjson pdb "$pdb_json" --argjson desired "$desired" '
        def min_keeps_one:
          if type == "number" then . >= 1
          elif type == "string" then test("^[1-9][0-9]*%$") or (test("^[1-9][0-9]*$") and tonumber >= 1)
          else false
          end;
        def max_keeps_one:
          if type == "number" then . >= 0 and . < $desired
          elif type == "string" and test("^[0-9]+$") then (tonumber >= 0 and tonumber < $desired)
          elif type == "string" and test("^[0-9]+%$") then
            ((sub("%$"; "") | tonumber) * $desired / 100 | ceil) < $desired
          else false
          end;
        (($pdb.status.disruptionsAllowed // 0) >= 1) and
        ((($pdb.spec.minAvailable // 0) | min_keeps_one) or
          (($pdb.spec.maxUnavailable // $desired) | max_keeps_one)) and
        (($pdb.spec.selector.matchLabels // {}) as $selector |
          ($selector | length) > 0 and
          all($selector | to_entries[]; $workload.spec.selector.matchLabels[.key] == .value))
      ')"
    fi
  fi

  if ((desired < minimum || ready < minimum || node_count < minimum)) ||
    [[ "$hard_spread" != true ]] ||
    [[ "$pdb_valid" != true ]]; then
    printf 'FAIL: %s kind=%s desired=%s ready=%s nodes=%s hard-spread=%s pdb-valid=%s\n' \
      "$service" "$kind" "$desired" "$ready" "$node_count" "$hard_spread" "$pdb_valid"
    failures=$((failures + 1))
  else
    printf 'PASS: %s kind=%s desired=%s ready=%s nodes=%s hard-spread=%s pdb-valid=%s\n' \
      "$service" "$kind" "$desired" "$ready" "$node_count" "$hard_spread" "$pdb_valid"
  fi
done < <(
  yq -r '
    .services[]
    | select(.class == "seamless")
    | [.name, .workload.kind, .workload.namespace, .workload.name, .workload.minReplicas, (.workload.pdb // "-")]
    | @tsv
  ' "$policy"
)

printf '\n%s\n' '=== Bounded-Recovery and management workload readiness ==='
while IFS=$'\t' read -r service class kind namespace name budget; do
  [[ -n "$service" ]] || continue
  resource_json="$(kubectl -n "$namespace" get "$kind" "$name" -o json)"
  if [[ "$kind" == clusters.postgresql.cnpg.io ]]; then
    desired="$(jq -r '.spec.instances // 0' <<<"$resource_json")"
    ready="$(jq -r '.status.readyInstances // 0' <<<"$resource_json")"
  else
    desired="$(jq -r '.spec.replicas // 1' <<<"$resource_json")"
    ready="$(jq -r '.status.readyReplicas // 0' <<<"$resource_json")"
  fi

  if ((desired < 1 || ready < 1)); then
    printf 'FAIL: %s class=%s desired=%s ready=%s budget=%ss\n' "$service" "$class" "$desired" "$ready" "$budget"
    failures=$((failures + 1))
  else
    printf 'PASS: %s class=%s desired=%s ready=%s budget=%ss\n' "$service" "$class" "$desired" "$ready" "$budget"
  fi
done < <(
  yq -r '
    .services[]
    | select(.class == "bounded-recovery" or .class == "management")
    | [.name, .class, .workload.kind, .workload.namespace, .workload.name, .recoveryBudgetSeconds]
    | @tsv
  ' "$policy"
)

printf '\n%s\n' '=== External dependencies excluded from the node-failure guarantee ==='
yq -r '
  .services[]
  | select(.class == "external-dependency")
  | [.name, .probe.type, .probe.target]
  | @tsv
' "$policy" | column -t -s $'\t'

printf '\n%s\n' '=== PodDisruptionBudgets ==='
kubectl get poddisruptionbudget -A \
  -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,MIN-AVAILABLE:.spec.minAvailable,MAX-UNAVAILABLE:.spec.maxUnavailable,ALLOWED-DISRUPTIONS:.status.disruptionsAllowed'

printf '\n%s\n' '=== CloudNativePG clusters ==='
if kubectl api-resources --api-group=postgresql.cnpg.io -o name | grep -qx 'clusters.postgresql.cnpg.io'; then
  kubectl get clusters.postgresql.cnpg.io -A \
    -o custom-columns='NAMESPACE:.metadata.namespace,NAME:.metadata.name,INSTANCES:.spec.instances,READY:.status.readyInstances,PRIMARY:.status.currentPrimary,PHASE:.status.phase'
  cnpg_health="$(
    kubectl get clusters.postgresql.cnpg.io -A -o json |
      jq '[.items[] | select((.spec.instances // 0) < 3 or (.status.readyInstances // 0) < 3 or .status.phase != "Cluster in healthy state")] | length'
  )"
  if ((cnpg_health > 0)); then
    echo "FAIL: $cnpg_health CloudNativePG cluster(s) do not satisfy the three-instance healthy-state gate."
    failures=$((failures + 1))
  else
    echo 'PASS: all CloudNativePG clusters satisfy the three-instance healthy-state gate.'
  fi
else
  echo 'FAIL: CloudNativePG CRDs are not installed.'
  failures=$((failures + 1))
fi

printf '\n%s\n' '=== CloudNativePG backup freshness ==='
for namespace in authentik matrix; do
  if "$repo_root/scripts/cnpg-backup-audit.sh" \
    --namespace "$namespace" \
    --cluster "$namespace-postgres" \
    --object-store "$namespace-postgres-backups"; then
    :
  else
    failures=$((failures + 1))
  fi
done

printf '\n%s\n' '=== Longhorn nodes ==='
kubectl -n longhorn-system get nodes.longhorn.io
longhorn_node_failures="$(
  kubectl -n longhorn-system get nodes.longhorn.io -o json |
    jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status != "True") or .spec.allowScheduling != true)] | length'
)"
longhorn_node_count="$(kubectl -n longhorn-system get nodes.longhorn.io -o json | jq '.items | length')"
if ((longhorn_node_count != 3 || longhorn_node_failures > 0)); then
  echo "FAIL: Longhorn requires exactly three Ready and schedulable nodes."
  failures=$((failures + 1))
else
  echo 'PASS: Longhorn has exactly three Ready and schedulable nodes.'
fi

printf '\n%s\n' '=== Longhorn StorageClasses ==='
kubectl get storageclass -o json | jq -r '
  .items[]
  | select(.provisioner == "driver.longhorn.io")
  | [
      .metadata.name,
      (.parameters.numberOfReplicas // ""),
      (.parameters.dataLocality // ""),
      (.volumeBindingMode // "")
    ]
  | @tsv
' | column -t -s $'\t'
longhorn_storageclass_replicas="$(
  kubectl get storageclass longhorn -o json |
    jq -r '.parameters.numberOfReplicas // ""'
)"
if [[ "$longhorn_storageclass_replicas" != 3 ]]; then
  echo "FAIL: Longhorn StorageClass replica count is '$longhorn_storageclass_replicas', expected '3'."
  failures=$((failures + 1))
else
  echo 'PASS: Longhorn StorageClass provisions three replicas.'
fi

printf '\n%s\n' '=== Longhorn volume replica placement ==='
replicas_json="$(kubectl -n longhorn-system get replicas.longhorn.io -o json)"
while IFS=$'\t' read -r volume state robustness desired; do
  placement="$(
    jq -r --arg volume "$volume" '
      [
        .items[]
        | select(.spec.volumeName == $volume)
        | select((.spec.failedAt // "") == "")
        | select(.spec.nodeID != "")
      ] as $replicas
      | [
          ($replicas | length),
          ($replicas | map(.spec.nodeID) | unique | length)
        ]
      | @tsv
    ' <<<"$replicas_json"
  )"
  read -r usable distinct_nodes <<<"$placement"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$volume" "$state" "$robustness" "$desired" "$usable" "$distinct_nodes"
  if [[ "$state" != attached && "$state" != detached ]] ||
    [[ "$robustness" != healthy ]] ||
    ((desired != 3 || usable != 3 || distinct_nodes != 3)); then
    failures=$((failures + 1))
  fi
done < <(kubectl -n longhorn-system get volumes.longhorn.io -o json | jq -r '
  .items[]
  | [.metadata.name, .status.state, .status.robustness, (.spec.numberOfReplicas | tostring)]
  | @tsv
')

printf '\n%s\n' 'Expected Longhorn result: every production volume is healthy and has three usable replicas on three distinct nodes.'

if ((failures > 0)); then
  printf '\nFAIL: availability audit found %s policy violation(s).\n' "$failures" >&2
  exit 1
fi

printf '\nPASS: target cluster satisfies the enforced availability policy.\n'
