#!/usr/bin/env bash
# Offline security contracts: ciphertext metadata only; no cluster or secret reads.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

[[ $# == 1 ]] || { echo "Supply exact rendered chart YAML (see docs/testing.md)" >&2; exit 2; }
for render in "$@"; do [[ -s "$render" ]] || { echo "Missing chart render: $render" >&2; exit 1; }; done
app=kubernetes/observability/alloy/app
# The encrypted password envelope is verified in the private source repository.
yq -e '.metadata.name == "alloy-secrets" and .spec.sourceRef.name == "homelab-secrets" and .spec.decryption.provider == "sops" and .spec.decryption.secretRef.name == "sops-age"' kubernetes/observability/alloy/secrets-ks.yaml >/dev/null
# Exactly two namespace-local grants, no cluster-wide Pods or Secret access.
yq -o=json -I=0 '.' "$app/logs-rbac.yaml" | jq -se '
  length == 4 and
  ([.[] | .metadata.namespace] | unique | sort) == ["kube-state-metrics","metrics-server"] and
  ([.[] | select(.kind == "Role")] | length) == 2 and
  all(.[] | select(.kind == "Role"); .metadata.name == "alloy-pod-logs" and .rules == [
    {"apiGroups":[""],"resources":["pods"],"verbs":["get","list","watch"]},
    {"apiGroups":[""],"resources":["pods/log"],"verbs":["get"]}]) and
  ([.[] | select(.kind == "RoleBinding")] | length) == 2 and
  all(.[] | select(.kind == "RoleBinding"); .metadata.name == "alloy-pod-logs" and
    .roleRef == {"apiGroup":"rbac.authorization.k8s.io","kind":"Role","name":"alloy-pod-logs"} and
    .subjects == [{"kind":"ServiceAccount","name":"alloy","namespace":"alloy"}])
' >/dev/null
config=$(yq -r '.spec.values.alloy.configMap.content' "$app/helmrelease.yaml")
discovery=$(printf '%s\n' "$config" | sed -n '/^discovery.kubernetes "logs" {/,/^}/p')
source=$(printf '%s\n' "$config" | sed -n '/^loki.source.kubernetes "scoped" {/,/^}/p')
writer=$(printf '%s\n' "$config" | sed -n '/^loki.write "oci_logs" {/,/^}/p')
[[ $(printf '%s\n' "$config" | rg -c '^loki.source.kubernetes ') == 1 ]]
for contract in 'role = "pod"' 'names = ["metrics-server", "kube-state-metrics"]' 'bearer_token_file = "/etc/alloy/kubelet-api/token"' 'ca_file = "/etc/alloy/kubelet-api/ca.crt"' 'follow_redirects = false'; do
  printf '%s\n' "$discovery" | tr -s ' ' | rg -F "$contract" >/dev/null
done
for contract in 'bearer_token_file = "/etc/alloy/kubelet-api/token"' 'ca_file = "/etc/alloy/kubelet-api/ca.crt"' 'follow_redirects = false'; do
  printf '%s\n' "$source" | tr -s ' ' | rg -F "$contract" >/dev/null
done
for contract in 'https://control-01.tailscale.svc.cluster.local/loki/api/v1/push' 'username = "talos-logs"' 'password_file = "/etc/alloy/logs-ingestion/password"' 'server_name = "metrics.${BASE_DOMAIN}"' 'follow_redirects = false' 'batch_size = "128KiB"' 'max_streams = 32' 'max_backoff_retries = 5'; do
  printf '%s\n' "$writer" | tr -s ' ' | rg -F "$contract" >/dev/null
done
# The existing kubelet-only trust exception cannot escape to either new client.
if printf '%s\n' "$discovery" "$source" "$writer" | rg -q 'insecure_skip_verify|queue_config|wal \{|stability.level|labelmap'; then
  echo 'FAIL: logs escaped stable/verified-client boundaries' >&2
  exit 1
fi
printf '%s\n' "$config" | rg -F 'regex  = "namespace|pod|container|job"' >/dev/null
for contract in 'older_than = "1h"' 'longer_than = "16KiB"' 'rate = 5' 'burst = 10' 'drop = true'; do
  printf '%s\n' "$config" | tr -s ' ' | rg -F "$contract" >/dev/null
done
yq -o=json '.spec.values' "$app/helmrelease.yaml" | jq -e '
  ([.controller.volumes.extra[] | select(.name == "logs-ingestion")][0].secret == {
    "secretName":"talos-logs-ingestion","optional":false,"defaultMode":288,"items":[{"key":"password","path":"password"}]}) and
  ([.alloy.mounts.extra[] | select(.name == "logs-ingestion")][0] == {
    "name":"logs-ingestion","mountPath":"/etc/alloy/logs-ingestion","readOnly":true})
' >/dev/null
  yq -o=json -I=0 '.' "$1" | jq -se '
    ([.[] | select(.kind == "StatefulSet")][0].spec.template.spec as $pod |
      ([ $pod.volumes[] | select(.name == "logs-ingestion") ][0].secret.secretName == "talos-logs-ingestion") and
      ([ $pod.containers[0].volumeMounts[] | select(.name == "logs-ingestion") ][0].readOnly == true) and
      ([ $pod.volumes[] | select(.name == "logs-ingestion") ][0].secret.optional == false))
  ' >/dev/null
echo 'PASS: scoped Pod/log RBAC, selected-v1 ciphertext, label/budget policy and stable trusted writer.'
