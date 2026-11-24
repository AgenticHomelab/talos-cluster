#!/usr/bin/env bash
# Local desired-state contract only: no live API, credential access or decryption.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

[[ $# == 2 ]] || { echo "Supply exact rendered chart YAML (see docs/testing.md)" >&2; exit 2; }
for render in "$@"; do [[ -s "$render" ]] || { echo "Missing chart render: $render" >&2; exit 1; }; done

for entry in "observability alloy" "observability kube-state-metrics"; do
  read -r unit_category unit <<<"$entry"
  yq -e '.spec.suspend == false' "kubernetes/$unit_category/$unit/ks.yaml" >/dev/null
  yq -e '.spec.suspend == false' "kubernetes/$unit_category/$unit/app/helmrelease.yaml" >/dev/null
done
# Verify the app-local Vault delivery contract without reading credentials.
kubectl kustomize kubernetes/observability/alloy/app | yq -e 'select(.kind == "ExternalSecret" and .metadata.name == "talos-metrics-ingestion") | .metadata.namespace == "alloy" and .spec.secretStoreRef.kind == "ClusterSecretStore" and .spec.secretStoreRef.name == "oci-vault" and .spec.target.name == "talos-metrics-ingestion" and .spec.target.creationPolicy == "Orphan" and .spec.target.deletionPolicy == "Retain" and .spec.dataFrom[0].extract.key == "k8s-alloy-talos-metrics-ingestion"' >/dev/null
alloy=kubernetes/observability/alloy/app/helmrelease.yaml
ksm=kubernetes/observability/kube-state-metrics/app/helmrelease.yaml
yq -e '.spec.values.alloy.enableReporting == false and .spec.values.controller.enableStatefulSetAutoDeletePVC == false' "$alloy" >/dev/null
yq -e '(.spec | has("decryption") | not) and (.spec.dependsOn | map(.name) | sort | join(",")) == "external-secrets-config,homelab-private-config,kube-state-metrics,longhorn,metrics-server,tailscale-config"' kubernetes/observability/alloy/ks.yaml >/dev/null
yq -e '.spec.values.controller.volumes.extra[0].secret.secretName == "talos-metrics-ingestion" and .spec.values.controller.volumes.extra[0].secret.optional == false and (.spec.values.controller.volumes.extra[0].secret.items | length) == 1 and .spec.values.controller.volumes.extra[0].secret.items[0].key == "password" and .spec.values.controller.volumes.extra[0].secret.items[0].path == "password" and .spec.values.alloy.mounts.extra[1].readOnly == true' "$alloy" >/dev/null
yq -e '(.spec.values.collectors | sort | join(",")) == "deployments,nodes,pods,statefulsets" and (.spec.values.rbac.extraRules | length) == 0' "$ksm" >/dev/null
config=$(yq -r '.spec.values.alloy.configMap.content' "$alloy")
[[ $(printf '%s\n' "$config" | rg -c '^prometheus.remote_write ') == 1 ]]
[[ $(printf '%s\n' "$config" | rg -c '^prometheus.scrape ') == 3 ]]
for contract in \
  'https://control-01.tailscale.svc.cluster.local/api/v1/write' \
  'password_file = "/etc/alloy/remote-write/password"' \
  'server_name = "metrics.${BASE_DOMAIN}"' \
  'follow_redirects = false' \
  '"cluster" = "talos-home"'; do
  printf '%s\n' "$config" | rg -F "$contract" >/dev/null
done
# The temporary trust exception must be local to the kubelet scrape, never OCI/API.
kubelet=$(printf '%s\n' "$config" | sed -n '/^prometheus.scrape "kubelet_resource" {/,/^}/p')
remote=$(printf '%s\n' "$config" | sed -n '/^prometheus.remote_write "oci" {/,/^}/p')
discovery=$(printf '%s\n' "$config" | sed -n '/^discovery.kubernetes "nodes" {/,/^}/p')
[[ $(printf '%s\n' "$config" | rg -c 'insecure_skip_verify = true') == 1 ]]
printf '%s\n' "$kubelet" | rg -F 'insecure_skip_verify = true' >/dev/null
if printf '%s\n' "$remote" | rg -q 'insecure_skip_verify|kubelet-api/token'; then
  echo "FAIL: kubelet trust/auth scope escaped its declared boundary" >&2
  exit 1
fi
if printf '%s\n' "$discovery" | rg -q 'insecure_skip_verify'; then
  echo "FAIL: kubelet trust/auth scope escaped its declared boundary" >&2
  exit 1
fi
for contract in 'role = "node"' 'ca_file = "/etc/alloy/kubelet-api/ca.crt"'; do
  printf '%s\n' "$discovery" | tr -s ' ' | rg -F "$contract" >/dev/null
done
for contract in 'metrics_path = "/metrics/resource"' 'job_name = "talos/kubelet-resource"' 'bearer_token_file = "/etc/alloy/kubelet-api/token"' 'follow_redirects = false' 'sample_limit = 5000' 'body_size_limit = "4MiB"'; do
  printf '%s\n' "$kubelet" | tr -s ' ' | rg -F "$contract" >/dev/null
done
filter=$(printf '%s\n' "$config" | sed -n '/^prometheus.relabel "kubelet_resource" {/,/^}/p')
printf '%s\n' "$filter" | rg -F '(node|pod|container)_cpu_usage_seconds_total|(node|pod|container)_memory_working_set_bytes|resource_scrape_error|up|scrape_(duration_seconds|samples_scraped|samples_post_metric_relabeling|series_added)' >/dev/null
printf '%s\n' "$filter" | rg -F '__name__|job|instance|node|namespace|pod|container' >/dev/null
if printf '%s\n' "$config" | rg -q 'nodes/proxy|/metrics/cadvisor'; then
  echo "FAIL: kubelet trust/auth scope escaped its declared boundary" >&2
  exit 1
fi
echo 'PASS: scoped node discovery/projection, kubelet-only trust exception, required Secret and bounded WAL.'

  for render in "$@"; do
    yq -o=json -I=0 '.' "$render" | jq -se '
      ([.[] | select(.kind == "Service")] | length) > 0 and
      ([.[] | select(.kind == "StatefulSet" or .kind == "Deployment")] | length) == 1 and
      ([.[] | select(.kind == "ClusterRole")] | length) == 1 and
      all(.[] | select(.kind == "Service"); .spec.type == "ClusterIP") and
      (any(.[]; .kind == "Ingress" or .kind == "Secret" or .kind == "CustomResourceDefinition" or .kind == "ServiceMonitor") | not) and
      all(.[] | select(.kind == "StatefulSet" or .kind == "Deployment");
        .spec.template.spec as $pod |
        ($pod.hostNetwork // false) == false and ($pod.hostPID // false) == false and
        $pod.securityContext.runAsNonRoot == true and
        $pod.securityContext.seccompProfile.type == "RuntimeDefault" and
        (any($pod.volumes[]?; has("hostPath")) | not) and
        all($pod.containers[];
          .securityContext.allowPrivilegeEscalation == false and
          .securityContext.readOnlyRootFilesystem == true and
          .securityContext.capabilities.drop == ["ALL"] and
          (.securityContext.privileged // false) == false and
          .resources.requests.cpu != null and .resources.requests.memory != null and
          .resources.limits.cpu != null and .resources.limits.memory != null))
    ' >/dev/null
  done
  yq -o=json -I=0 '.' "$1" | jq -se '
    ([.[] | select(.kind == "ClusterRole")] | length) == 1 and
    ([.[] | select(.kind == "ClusterRole")][0].rules == [
      {"apiGroups":[""],"resources":["nodes"],"verbs":["list","watch"]},
      {"apiGroups":[""],"resources":["nodes/metrics"],"verbs":["get"]}]) and
    ([.[] | select(.kind == "ClusterRoleBinding")][0] | .roleRef.name == "alloy" and .subjects == [{"kind":"ServiceAccount","name":"alloy","namespace":"alloy"}]) and
    (any(.[]; .kind == "Role" or .kind == "RoleBinding") | not) and
    all(.[] | select(.kind == "ServiceAccount"); .automountServiceAccountToken == false) and
    all(.[] | select(.kind == "StatefulSet");
      .spec.replicas == 1 and (.spec.template.spec.containers | length) == 1 and
      .spec.volumeClaimTemplates[0].spec.resources.requests.storage == "2Gi" and
      .spec.volumeClaimTemplates[0].spec.storageClassName == "longhorn" and
      .spec.volumeClaimTemplates[0].spec.accessModes == ["ReadWriteOnce"] and
      ([.spec.template.spec.volumes[] | select(.name == "remote-write")][0].secret.optional == false) and
      ([.spec.template.spec.containers[0].volumeMounts[] | select(.name == "remote-write")][0].readOnly == true) and
      ([.spec.template.spec.volumes[] | select(.name == "kubelet-api")][0].projected as $projection |
        $projection.defaultMode == 288 and
        $projection.sources == [{"serviceAccountToken":{"path":"token","expirationSeconds":3600}},
          {"configMap":{"name":"kube-root-ca.crt","items":[{"key":"ca.crt","path":"ca.crt"}]}}]) and
      ([.spec.template.spec.containers[0].volumeMounts[] | select(.name == "kubelet-api")][0] |
        .mountPath == "/etc/alloy/kubelet-api" and .readOnly == true and (has("subPath") | not)))
  ' >/dev/null
  yq -o=json -I=0 '.' "$2" | jq -se '
    all(.[] | select(.kind == "ClusterRole");
      (.rules | length) == 4 and
      ([.rules[].resources[]] | sort) == ["deployments", "nodes", "pods", "statefulsets"] and
      all(.rules[]; (.verbs | sort) == ["list", "watch"]))
  ' >/dev/null
  echo 'PASS: native rendered security contexts, singleton PVC/mounts and exact read-only RBAC.'
