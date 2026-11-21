#!/usr/bin/env bash
set -euo pipefail

namespace='network-policy-probe'
image='docker.io/library/busybox:1.38.0@sha256:fd8d9aa63ba2f0982b5304e1ee8d3b90a210bc1ffb5314d980eb6962f1a9715d'
usage() {
  printf 'Usage: %s TARGET_SERVICE_DNS_NAME [PORT] [TIMEOUT_SECONDS]\n' "$(basename "$0")" >&2
}

host="${1:-}"
port="${2:-80}"
timeout="${3:-5}"

if [[ -z "$host" ]]; then
  usage
  exit 2
fi
[[ "$host" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || {
  echo "Target must be a DNS name: $host" >&2
  exit 2
}
[[ "$port" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535)) || {
  echo "Port must be an integer from 1 to 65535: $port" >&2
  exit 2
}
[[ "$timeout" =~ ^[0-9]+$ ]] && ((timeout >= 1 && timeout <= 30)) || {
  echo "Timeout must be an integer from 1 to 30 seconds: $timeout" >&2
  exit 2
}

api_timeout=$((timeout < 5 ? 5 : timeout))
job_resource=''
cleanup() {
  if [[ -n "$job_resource" ]]; then
    kubectl delete "$job_resource" \
      --namespace "$namespace" \
      --ignore-not-found \
      --wait=false \
      --request-timeout="${api_timeout}s" \
      >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

job_resource="$(kubectl create -f - -o name --request-timeout="${api_timeout}s" <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  generateName: network-policy-probe-
  namespace: ${namespace}
  labels:
    app.kubernetes.io/name: network-policy-probe
    app.kubernetes.io/part-of: hermes-validation
spec:
  backoffLimit: 0
  activeDeadlineSeconds: $((timeout + 20))
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app.kubernetes.io/name: network-policy-probe
        app.kubernetes.io/part-of: hermes-validation
    spec:
      automountServiceAccountToken: false
      restartPolicy: Never
      securityContext:
        runAsNonRoot: true
        runAsUser: 65532
        runAsGroup: 65532
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: probe
          image: ${image}
          imagePullPolicy: IfNotPresent
          command:
            - /probe/probe.sh
          args:
            - ${host}
            - "${port}"
            - "${timeout}"
          resources:
            requests:
              cpu: 5m
              memory: 16Mi
            limits:
              cpu: 50m
              memory: 32Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: probe-script
              mountPath: /probe
              readOnly: true
      volumes:
        - name: probe-script
          configMap:
            name: network-policy-probe-script
            defaultMode: 0555
EOF
)"

poll_budget=$((timeout + 30))
poll_deadline=$((SECONDS + poll_budget))
job_name="${job_resource##*/}"
job_terminal_status=''
poll_failure=''
job_json=''

while :; do
  if ((SECONDS >= poll_deadline)); then
    poll_failure="Job status polling deadline expired after approximately ${poll_budget}s"
    break
  fi

  if ! job_json="$(kubectl get "$job_resource" \
    --namespace "$namespace" \
    --output=json \
    --request-timeout="${api_timeout}s" \
    2>/dev/null)"; then
    poll_failure="kubectl get failed while polling Job status"
    break
  fi

  if ! status_values="$(printf '%s\n' "$job_json" | jq -er '
    def count($key):
      ((.status // {})[$key] // 0)
      | if (type == "number" and . >= 0 and floor == .) then tostring else error end;
    [count("succeeded"), count("failed")] | @tsv
  ')"; then
    poll_failure="Job status contained an invalid succeeded/failed value"
    break
  fi
  IFS=$'\t' read -r succeeded failed <<< "$status_values"

  if ((succeeded >= 1)); then
    job_terminal_status='succeeded'
    break
  fi
  if ((failed >= 1)); then
    job_terminal_status='failed'
    break
  fi

  sleep 1
done

logs_status=0
if ! kubectl logs "$job_resource" \
  --namespace "$namespace" \
  --all-containers=true \
  --pod-running-timeout="${api_timeout}s" \
  --request-timeout="${api_timeout}s"; then
  logs_status=1
  echo "Unable to read available logs for probe Job: $job_resource" >&2
fi

if [[ "$job_terminal_status" == 'succeeded' ]]; then
  if ! pod_json="$(kubectl get pods \
    --namespace "$namespace" \
    --selector="batch.kubernetes.io/job-name=${job_name}" \
    --output=json \
    --request-timeout="${api_timeout}s" \
    2>/dev/null)"; then
    echo "Unable to inspect the succeeded probe container: $job_resource" >&2
    exit 1
  fi

  if ! probe_completed="$(printf '%s\n' "$pod_json" | jq -er '
    any(.items[]?;
      .status.phase == "Succeeded" and
      any(.status.containerStatuses[]?;
        .name == "probe" and
        .state.terminated.exitCode == 0 and
        .state.terminated.reason == "Completed"
      )
    )
  ')"; then
    echo "Unable to interpret the succeeded probe container status: $job_resource" >&2
    exit 1
  fi
  if [[ "$probe_completed" != 'true' ]]; then
    echo "Job succeeded without a successfully completed probe container: $job_resource" >&2
    exit 1
  fi
  if ((logs_status != 0)); then
    exit 1
  fi
  echo "NetworkPolicy probe completed: DNS resolved and transport timeout/drop matched expected deny semantics."
  exit 0
fi

if [[ "$job_terminal_status" == 'failed' ]]; then
  echo "NetworkPolicy probe Job failed: $job_resource" >&2
else
  [[ -n "$poll_failure" ]] || poll_failure='Job status polling failed closed'
  echo "$poll_failure: $job_resource" >&2
fi
exit 1
