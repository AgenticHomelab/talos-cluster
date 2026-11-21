#!/usr/bin/env bash
set -euo pipefail

TARGET_REPLICAS="${TARGET_REPLICAS:-3}"
WAIT_SECONDS="${WAIT_SECONDS:-3600}"
NAMESPACE="longhorn-system"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

require kubectl
require jq

healthy_nodes="$(
  kubectl -n "$NAMESPACE" get nodes.longhorn.io -o json |
    jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) | select(any(.status.conditions[]?; .type == "Schedulable" and .status == "True"))] | length'
)"

if (( healthy_nodes < TARGET_REPLICAS )); then
  echo "Need at least ${TARGET_REPLICAS} Ready and Schedulable Longhorn nodes; found ${healthy_nodes}." >&2
  exit 1
fi

mapfile -t volumes < <(
  kubectl -n "$NAMESPACE" get volumes.longhorn.io \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | sort
)

for volume in "${volumes[@]}"; do
  state="$(kubectl -n "$NAMESPACE" get volumes.longhorn.io "$volume" -o jsonpath='{.status.state}')"
  robustness="$(kubectl -n "$NAMESPACE" get volumes.longhorn.io "$volume" -o jsonpath='{.status.robustness}')"
  current="$(kubectl -n "$NAMESPACE" get volumes.longhorn.io "$volume" -o jsonpath='{.spec.numberOfReplicas}')"

  printf '%s: state=%s robustness=%s desired-replicas=%s\n' "$volume" "$state" "$robustness" "$current"

  if [[ "$state" != "attached" ]]; then
    echo "Refusing to modify a detached volume: $volume. Start its workload first." >&2
    exit 1
  fi

  if [[ "$robustness" != "healthy" ]]; then
    echo "Refusing to modify an unhealthy volume: $volume" >&2
    exit 1
  fi

  if (( current < TARGET_REPLICAS )); then
    kubectl -n "$NAMESPACE" patch volumes.longhorn.io "$volume" \
      --type=merge \
      -p "{\"spec\":{\"numberOfReplicas\":${TARGET_REPLICAS}}}"
  fi

  deadline=$((SECONDS + WAIT_SECONDS))

  while true; do
    robustness="$(kubectl -n "$NAMESPACE" get volumes.longhorn.io "$volume" -o jsonpath='{.status.robustness}')"
    placement="$(
      kubectl -n "$NAMESPACE" get replicas.longhorn.io -o json |
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
        '
    )"

    read -r usable_replicas distinct_nodes <<<"$placement"

    printf '  robustness=%s usable-replicas=%s distinct-nodes=%s\n' \
      "$robustness" "$usable_replicas" "$distinct_nodes"

    if [[ "$robustness" == "healthy" ]] && \
       (( usable_replicas >= TARGET_REPLICAS )) && \
       (( distinct_nodes >= TARGET_REPLICAS )); then
      break
    fi

    if (( SECONDS >= deadline )); then
      echo "Timed out waiting for volume $volume to reach ${TARGET_REPLICAS} healthy placements." >&2
      exit 1
    fi

    sleep 10
  done
done
