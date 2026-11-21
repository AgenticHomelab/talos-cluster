#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
app="$repo_root/kubernetes/infrastructure/network-policy-probe/app"
namespace="$repo_root/kubernetes/infrastructure/network-policy-probe/namespace.yaml"
probe_wrapper="$repo_root/scripts/network-policy-probe.sh"
tmpdir="$(mktemp -d "$repo_root/.network-policy-probe-test.XXXXXX")"
trap 'rm -rf "$tmpdir"' EXIT

rendered="$tmpdir/rendered.yaml"
kubectl kustomize "$app" > "$rendered"

assert_value() {
  local expression="$1" expected="$2" file="$3" actual
  actual="$(yq -r "$expression" "$file")"
  [[ "$actual" == "$expected" ]] || {
    echo "unexpected value for $expression: $actual" >&2
    exit 1
  }
}

assert_value '.metadata.name' 'network-policy-probe' "$namespace"
assert_value '.metadata.labels."pod-security.kubernetes.io/enforce"' 'restricted' "$namespace"
assert_value '.metadata.labels."pod-security.kubernetes.io/audit"' 'restricted' "$namespace"
assert_value '.metadata.labels."pod-security.kubernetes.io/warn"' 'restricted' "$namespace"

if yq -o=json -I=0 '.' "$rendered" | jq -s -e 'any(.[]; .kind == "Job")' >/dev/null; then
  echo 'probe Flux unit must not install a persistent Job' >&2
  exit 1
fi

script="$tmpdir/probe.sh"
yq -r 'select(.kind == "ConfigMap" and .metadata.name == "network-policy-probe-script") | .data."probe.sh"' "$rendered" > "$script"
chmod +x "$script"

fake_bin="$tmpdir/probe-bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/nslookup" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${DNS_MODE:-success}" == failure ]]; then
  printf 'server failure\n' >&2
  exit 1
fi
printf 'Name: %s\nAddress: 192.0.2.24\n' "${1:-target}"
EOF
cat > "$fake_bin/wget" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${WGET_MODE:-transport}" in
  http-200)
    printf '  HTTP/1.1 200 OK\n  Content-Length: 0\n'
    exit 0
    ;;
  http-404)
    printf 'wget: server returned error: HTTP/1.1 404 Not Found\n'
    exit 8
    ;;
  refused)
    printf "wget: can't connect to remote host: Connection refused\n"
    exit 1
    ;;
  transport)
    printf 'wget: download timed out\n'
    exit 1
    ;;
  unknown)
    printf 'wget: protocol error\n'
    exit 1
    ;;
  *)
    printf 'unknown fake wget mode\n' >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_bin/nslookup" "$fake_bin/wget"

run_probe() {
  local mode="$1" expected_exit="$2" expected_marker="$3"
  local output="$tmpdir/$mode.out" actual_exit
  set +e
  DNS_MODE="${DNS_MODE_FOR_TEST:-success}" WGET_MODE="$mode" PATH="$fake_bin:$PATH" \
    "$script" whoami.whoami.svc.cluster.local 80 5 > "$output" 2>&1
  actual_exit=$?
  set -e
  [[ "$actual_exit" -eq "$expected_exit" ]] || {
    echo "$mode expected exit $expected_exit, got $actual_exit" >&2
    cat "$output" >&2
    exit 1
  }
  rg -q "$expected_marker" "$output" || {
    echo "$mode did not produce expected marker: $expected_marker" >&2
    cat "$output" >&2
    exit 1
  }
}

run_probe http-200 1 'CONNECTION_RESULT=unexpected-http-response'
run_probe http-404 1 'CONNECTION_RESULT=unexpected-http-response'
run_probe refused 1 'CONNECTION_RESULT=unexpected-connection-refused'
run_probe transport 0 'CONNECTION_RESULT=expected-network-policy-drop'
run_probe unknown 1 'CONNECTION_RESULT=ambiguous-transport-failure'
DNS_MODE_FOR_TEST=failure run_probe transport 2 'DNS_RESOLUTION=failed'

fake_kubectl="$tmpdir/kubectl"
capture="$tmpdir/job.yaml"
calls="$tmpdir/kubectl.calls"
get_count="$tmpdir/get.count"
cat > "$fake_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FAKE_KUBECTL_CALLS"
case "${1:-}" in
  create)
    cat > "$FAKE_KUBECTL_CAPTURE"
    printf 'job.batch/network-policy-probe-test\n'
    ;;
  get)
    if [[ "$*" == *' pods '* ]]; then
      printf '{"items":[{"status":{"phase":"Succeeded","containerStatuses":[{"name":"probe","state":{"terminated":{"exitCode":0,"reason":"Completed"}}}]}}]}\n'
      exit 0
    fi
    count=0
    if [[ -f "$FAKE_KUBECTL_GET_COUNT" ]]; then
      read -r count < "$FAKE_KUBECTL_GET_COUNT"
    fi
    count=$((count + 1))
    printf '%s\n' "$count" > "$FAKE_KUBECTL_GET_COUNT"
    case "${FAKE_KUBECTL_GET_MODE:-success}" in
      success)
        if ((count >= 2)); then
          printf '{"status":{"succeeded":1}}\n'
        else
          printf '{"status":{}}\n'
        fi
        ;;
      failed)
        printf '{"status":{"failed":1}}\n'
        ;;
      timeout)
        printf '{"status":{}}\n'
        ;;
      get-error)
        printf 'simulated kubectl get error\n' >&2
        exit 1
        ;;
      *)
        printf '{"status":{"succeeded":"invalid"}}\n'
        ;;
    esac
    ;;
  logs)
    printf 'DNS_RESOLUTION=success\nCONNECTION_RESULT=expected-network-policy-drop\n'
    ;;
  delete)
    exit 0
    ;;
  wait)
    printf 'kubectl wait must not be called\n' >&2
    exit 1
    ;;
  *)
    printf 'unexpected kubectl command: %s\n' "$*" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$fake_kubectl"

run_wrapper() {
  local mode="$1" expected_exit="$2"
  local output="$tmpdir/wrapper-$mode.out" actual_exit
  rm -f "$capture" "$calls" "$get_count"
  set +e
  FAKE_KUBECTL_CAPTURE="$capture" \
  FAKE_KUBECTL_CALLS="$calls" \
  FAKE_KUBECTL_GET_COUNT="$get_count" \
  FAKE_KUBECTL_GET_MODE="$mode" \
    PATH="$tmpdir:$PATH" "$probe_wrapper" whoami.whoami.svc.cluster.local 80 "$([[ "$mode" == timeout ]] && printf 1 || printf 5)" > "$output" 2>&1
  actual_exit=$?
  set -e
  [[ "$actual_exit" -eq "$expected_exit" ]] || {
    echo "wrapper $mode expected exit $expected_exit, got $actual_exit" >&2
    cat "$output" >&2
    exit 1
  }
  rg -q '^delete ' "$calls" || {
    echo "wrapper $mode did not delete its generated Job" >&2
    cat "$calls" >&2
    exit 1
  }
  if rg -q '^wait ' "$calls"; then
    echo "wrapper $mode invoked kubectl wait" >&2
    exit 1
  fi
  rg -q '^create .*--request-timeout=5s' "$calls" || {
    echo "wrapper $mode did not bound kubectl create" >&2
    cat "$calls" >&2
    exit 1
  }
  rg -q '^get .*--request-timeout=5s' "$calls" || {
    echo "wrapper $mode did not bound kubectl get" >&2
    cat "$calls" >&2
    exit 1
  }
  rg -q '^logs .*--request-timeout=5s' "$calls" || {
    echo "wrapper $mode did not bound kubectl logs" >&2
    cat "$calls" >&2
    exit 1
  }
  rg -q '^delete .*--wait=false .*--request-timeout=5s' "$calls" || {
    echo "wrapper $mode did not use bounded non-blocking cleanup" >&2
    cat "$calls" >&2
    exit 1
  }
  if rg -q '^delete .*--wait=true' "$calls"; then
    echo "wrapper $mode used blocking cleanup" >&2
    exit 1
  fi
}

run_wrapper success 0
python3 -c 'import sys; lines=open(sys.argv[1]).read().splitlines(); assert next(i for i,x in enumerate(lines) if x.startswith("logs ")) < next(i for i,x in enumerate(lines) if x.startswith("get ") and "pods" in x), lines' "$calls"
run_wrapper failed 1
python3 -c 'import sys; lines=open(sys.argv[1]).read().splitlines(); assert next(i for i,x in enumerate(lines) if x.startswith("logs ")) < next(i for i,x in enumerate(lines) if x.startswith("delete ")), lines' "$calls"
run_wrapper timeout 1
run_wrapper get-error 1

echo 'PASS: network-policy validation harness covers mount, HTTP/transport classification, Job status polling and cleanup'
