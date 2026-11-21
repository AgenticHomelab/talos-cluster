#!/usr/bin/env bash
set -euo pipefail

NODE="${1:-}"
NAMESPACE="default"

if [[ -z "$NODE" ]]; then
  echo "Usage: $0 <kubernetes-node-name>" >&2
  exit 1
fi

for command in kubectl jq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

if ! kubectl get node "$NODE" >/dev/null 2>&1; then
  echo "Node not found: $NODE" >&2
  exit 1
fi

safe_node="$(printf '%s' "$NODE" | tr -cs 'a-zA-Z0-9-' '-')"
POD="network-check-${safe_node,,}"

cleanup() {
  kubectl -n "$NAMESPACE" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

cleanup

cat <<EOF_POD | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NAMESPACE}
spec:
  nodeName: ${NODE}
  restartPolicy: Never
  tolerations:
    - operator: Exists
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    runAsGroup: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: check
      image: busybox:1.36
      command:
        - sleep
        - "3600"
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop:
            - ALL
EOF_POD

kubectl -n "$NAMESPACE" wait \
  --for=condition=Ready \
  "pod/${POD}" \
  --timeout=120s

printf '%s\n' '=== Cluster DNS and Service routing ==='
kubectl -n "$NAMESPACE" exec "$POD" -- \
  nslookup kubernetes.default.svc.cluster.local

kubectl -n "$NAMESPACE" exec "$POD" -- sh -eu -c '
  wget -T 5 -qO /dev/null http://longhorn-backend.longhorn-system.svc:9500/v1
'

check_remote_endpoints() {
  local endpoint_namespace="$1"
  local service_name="$2"
  local protocol="$3"
  local port="$4"
  local found=0

  while IFS=$'\t' read -r address pod_name; do
    [[ -n "$address" && -n "$pod_name" ]] || continue

    endpoint_node="$(
      kubectl -n "$endpoint_namespace" get pod "$pod_name" \
        -o jsonpath='{.spec.nodeName}'
    )"

    [[ "$endpoint_node" != "$NODE" ]] || continue
    found=1

    printf 'Testing %s endpoint %s on %s\n' "$service_name" "$address" "$endpoint_node"

    case "$protocol" in
      dns)
        kubectl -n "$NAMESPACE" exec "$POD" -- \
          nslookup kubernetes.default.svc.cluster.local "$address"
        ;;
      http)
        kubectl -n "$NAMESPACE" exec "$POD" -- sh -eu -c \
          "wget -T 5 -qO /dev/null http://${address}:${port}/v1"
        ;;
      *)
        echo "Unknown endpoint protocol: $protocol" >&2
        exit 1
        ;;
    esac
  done < <(
    kubectl -n "$endpoint_namespace" get endpointslice \
      -l "kubernetes.io/service-name=${service_name}" \
      -o json |
      jq -r '
        .items[].endpoints[]
        | select(.conditions.ready != false)
        | select(.targetRef.kind == "Pod")
        | [.addresses[0], .targetRef.name]
        | @tsv
      '
  )

  if (( found == 0 )); then
    echo "No remote Ready endpoints found for ${endpoint_namespace}/${service_name}." >&2
    exit 1
  fi
}

printf '\n%s\n' '=== Direct cross-node CoreDNS endpoints ==='
check_remote_endpoints kube-system kube-dns dns 53

printf '\n%s\n' '=== Direct cross-node Longhorn manager endpoints ==='
check_remote_endpoints longhorn-system longhorn-backend http 9500

printf '\nPASS: %s has working pod, DNS, Service and cross-node overlay networking.\n' "$NODE"
