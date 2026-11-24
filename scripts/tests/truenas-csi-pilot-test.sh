#!/usr/bin/env bash
set -euo pipefail
trap 'echo "FAIL: TrueNAS CSI desired-state contract at line $LINENO" >&2' ERR

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
release="$repo_root/kubernetes/infrastructure/truenas-csi/app/helmrelease.yaml"
rendered="${1:?usage: truenas-csi-pilot-test.sh RENDERED_HELM_OUTPUT}"

yq -e '
  .spec.suspend != true and
  .spec.values.truenas.url == "wss://truenas-api.${BASE_DOMAIN}:444/api/current" and
  .spec.values.truenas.defaultPool == "tank" and
  .spec.values.truenas.nfsServer == "${NAS_HOST_IP}" and
  .spec.values.truenas.insecureSkipTLS == false and
  .spec.values.truenas.existingSecret == "truenas-csi-api" and
  .spec.values.truenas.existingSecretKey == "api-key" and
  .spec.values.volumeSnapshotClass.enabled == false
' "$release" >/dev/null

# Compare the exact transitional contracts, preserving all existing classes
# until the retained volumes have been rebound and pilot resources retired.
if ! yq -o=json '.spec.values.storageClasses' "$release" | jq -e '. == [
  {
    "name": "truenas-csi-pilot-delete",
    "isDefault": false,
    "reclaimPolicy": "Delete",
    "allowVolumeExpansion": true,
    "volumeBindingMode": "Immediate",
    "mountOptions": ["hard", "nfsvers=4.1"],
    "parameters": {
      "protocol": "nfs",
      "datasetPath": "k8s/csi-pilot/delete",
      "compression": "LZ4",
      "nfs.hosts": "${TRUENAS_NFS_CLIENT_HOSTS}"
    }
  },
  {
    "name": "truenas-csi-pilot-retain",
    "isDefault": false,
    "reclaimPolicy": "Retain",
    "allowVolumeExpansion": true,
    "volumeBindingMode": "Immediate",
    "mountOptions": ["hard", "nfsvers=4.1"],
    "parameters": {
      "protocol": "nfs",
      "datasetPath": "k8s/csi-pilot/retain",
      "compression": "LZ4",
      "nfs.hosts": "${TRUENAS_NFS_CLIENT_HOSTS}"
    }
  },
  {
    "name": "truenas-csi-production-retain",
    "isDefault": false,
    "reclaimPolicy": "Retain",
    "allowVolumeExpansion": true,
    "volumeBindingMode": "Immediate",
    "mountOptions": ["hard", "nfsvers=4.1", "sec=sys"],
    "parameters": {
      "protocol": "nfs",
      "datasetPath": "k8s/csi",
      "compression": "LZ4",
      "nfs.rootSquash": "false",
      "nfs.hosts": "${TRUENAS_NFS_CLIENT_HOSTS}"
    }
  },
  {
    "name": "truenas-csi-retain",
    "isDefault": false,
    "reclaimPolicy": "Retain",
    "allowVolumeExpansion": true,
    "volumeBindingMode": "Immediate",
    "mountOptions": ["hard", "nfsvers=4.1", "sec=sys"],
    "parameters": {
      "protocol": "nfs",
      "datasetPath": "k8s/csi",
      "compression": "LZ4",
      "nfs.rootSquash": "false",
      "nfs.hosts": "${TRUENAS_NFS_CLIENT_HOSTS}"
    }
  },
  {
    "name": "truenas-csi-delete",
    "isDefault": false,
    "reclaimPolicy": "Delete",
    "allowVolumeExpansion": true,
    "volumeBindingMode": "Immediate",
    "mountOptions": ["hard", "nfsvers=4.1", "sec=sys"],
    "parameters": {
      "protocol": "nfs",
      "datasetPath": "k8s/csi-delete",
      "compression": "LZ4",
      "nfs.rootSquash": "false",
      "nfs.hosts": "${TRUENAS_NFS_CLIENT_HOSTS}"
    }
  }
]' >/dev/null; then
  echo "Source CSI StorageClasses differ from the exact approved transitional contracts." >&2
  exit 1
fi

yq -e '
  (.spec.postRenderers | length) == 1 and
  .spec.postRenderers[0].kustomize.patches[0].target.group == "apps" and
  .spec.postRenderers[0].kustomize.patches[0].target.version == "v1" and
  .spec.postRenderers[0].kustomize.patches[0].target.kind == "DaemonSet" and
  .spec.postRenderers[0].kustomize.patches[0].target.name == "truenas-csi-node"
' "$release" >/dev/null
node_patch="$(yq -r '.spec.postRenderers[0].kustomize.patches[0].patch' "$release")"
yq -p=yaml -e '
  .apiVersion == "apps/v1" and
  .kind == "DaemonSet" and
  .metadata.name == "truenas-csi-node" and
  ([.spec.template.spec.volumes[] |
    select(.name == "iscsi-dir" and .hostPath.type == "DirectoryOrCreate")] | length) == 1
' <<<"$node_patch" >/dev/null

# Verify app-local Vault delivery while preserving the existing Secret reference.
kubectl kustomize "$repo_root/kubernetes/infrastructure/truenas-csi/app" | yq -e 'select(.kind == "ExternalSecret" and .metadata.name == "truenas-csi-api") | .metadata.namespace == "truenas-csi" and .spec.secretStoreRef.kind == "ClusterSecretStore" and .spec.secretStoreRef.name == "oci-vault" and .spec.target.name == "truenas-csi-api" and .spec.target.creationPolicy == "Orphan" and .spec.target.deletionPolicy == "Retain" and .spec.dataFrom[0].extract.key == "k8s-truenas-csi-truenas-csi-api"' >/dev/null
yq -e '(.spec.dependsOn | map(.name) | sort | join(",")) == "external-secrets-config,homelab-private-config"' "$repo_root/kubernetes/infrastructure/truenas-csi/ks.yaml" >/dev/null

if rg -q 'existingCABundleConfigMap|caBundle:' "$release"; then
  echo "The public CA trust path must not add a redundant CA bundle." >&2
  exit 1
fi

expected=
actual="$(yq -r '
  select(.kind == "StorageClass") |
  [.metadata.name, .reclaimPolicy,
   (.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false"),
   .parameters.datasetPath, (.mountOptions | join(","))] | @tsv
' "$rendered" | rg -v '^(---)?$' | sort)"
if [[ "$actual" != "$expected" ]]; then
  echo "Rendered StorageClasses do not match the approved pilot and production contracts." >&2
  exit 1
fi

if [[ "$(yq -r 'select(.kind == "StorageClass") | .metadata.name' "$rendered" | rg -v '^(---)?$' | wc -l)" -ne 5 ]]; then
  echo "Expected three legacy classes and two new classes." >&2
  exit 1
fi

# Check the rendered provisioner, binding, expansion and NFS parameter contract.
yq -o=json 'select(.kind == "StorageClass")' "$rendered" | jq -se '
  length == 5 and all(.[];
    .provisioner == "csi.truenas.io" and
    .volumeBindingMode == "Immediate" and
    .allowVolumeExpansion == true and
    .parameters.protocol == "nfs" and
    .parameters.compression == "LZ4" and
    .parameters["nfs.hosts"] == "${TRUENAS_NFS_CLIENT_HOSTS}" and
    (if (.metadata.name == "truenas-csi-delete" or
         .metadata.name == "truenas-csi-retain" or
         .metadata.name == "truenas-csi-production-retain")
     then .parameters["nfs.rootSquash"] == "false"
     else true end))
' >/dev/null

if rg -q '^kind: Secret
  echo "The upstream Helm chart must not generate credentials." >&2
  exit 1
fi

driver_names="$(yq -r 'select(.kind == "CSIDriver") | .metadata.name' "$rendered" | rg -v '^(---)?$')"
if [[ "$driver_names" != "csi.truenas.io" ]]; then
  echo "Unexpected CSI driver name(s): $driver_names" >&2
  exit 1
fi

echo "PASS: TrueNAS CSI transitional classes preserve TLS, ESO, non-default reclaim policies and NFS boundaries."
truenas-csi-delete\tDelete\tfalse\tk8s/csi-delete\thard,nfsvers=4.1,sec=sys\ntruenas-csi-pilot-delete\tDelete\tfalse\tk8s/csi-pilot/delete\thard,nfsvers=4.1\ntruenas-csi-pilot-retain\tRetain\tfalse\tk8s/csi-pilot/retain\thard,nfsvers=4.1\ntruenas-csi-production-retain\tRetain\tfalse\tk8s/csi\thard,nfsvers=4.1,sec=sys\ntruenas-csi-retain\tRetain\tfalse\tk8s/csi\thard,nfsvers=4.1,sec=sys'
actual="$(yq -r '
  select(.kind == "StorageClass") |
  [.metadata.name, .reclaimPolicy,
   (.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false"),
   .parameters.datasetPath, (.mountOptions | join(","))] | @tsv
' "$rendered" | rg -v '^(---)?$' | sort)"
if [[ "$actual" != "$expected" ]]; then
  echo "Rendered StorageClasses do not match the approved pilot and production contracts." >&2
  exit 1
fi

if [[ "$(yq -r 'select(.kind == "StorageClass") | .metadata.name' "$rendered" | rg -v '^(---)?$' | wc -l)" -ne 3 ]]; then
  echo "Expected two pilot classes and one production class." >&2
  exit 1
fi

if rg -q '^kind: Secret$' "$rendered"; then
  echo "The upstream Helm chart must not generate credentials." >&2
  exit 1
fi

driver_names="$(yq -r 'select(.kind == "CSIDriver") | .metadata.name' "$rendered" | rg -v '^(---)?$')"
if [[ "$driver_names" != "csi.truenas.io" ]]; then
  echo "Unexpected CSI driver name(s): $driver_names" >&2
  exit 1
fi

echo "PASS: TrueNAS CSI pilot and production classes preserve TLS, ESO, non-default Retain and NFS boundaries."
 "$rendered"; then
  echo "The upstream Helm chart must not generate credentials." >&2
  exit 1
fi

driver_names="$(yq -r 'select(.kind == "CSIDriver") | .metadata.name' "$rendered" | rg -v '^(---)?$')"
if [[ "$driver_names" != "csi.truenas.io" ]]; then
  echo "Unexpected CSI driver name(s): $driver_names" >&2
  exit 1
fi

echo "PASS: TrueNAS CSI transitional classes preserve TLS, ESO, non-default reclaim policies and NFS boundaries."
truenas-csi-delete\tDelete\tfalse\tk8s/csi-delete\thard,nfsvers=4.1,sec=sys\ntruenas-csi-pilot-delete\tDelete\tfalse\tk8s/csi-pilot/delete\thard,nfsvers=4.1\ntruenas-csi-pilot-retain\tRetain\tfalse\tk8s/csi-pilot/retain\thard,nfsvers=4.1\ntruenas-csi-production-retain\tRetain\tfalse\tk8s/csi\thard,nfsvers=4.1,sec=sys\ntruenas-csi-retain\tRetain\tfalse\tk8s/csi\thard,nfsvers=4.1,sec=sys'
actual="$(yq -r '
  select(.kind == "StorageClass") |
  [.metadata.name, .reclaimPolicy,
   (.metadata.annotations["storageclass.kubernetes.io/is-default-class"] // "false"),
   .parameters.datasetPath, (.mountOptions | join(","))] | @tsv
' "$rendered" | rg -v '^(---)?$' | sort)"
if [[ "$actual" != "$expected" ]]; then
  echo "Rendered StorageClasses do not match the approved pilot and production contracts." >&2
  exit 1
fi

if [[ "$(yq -r 'select(.kind == "StorageClass") | .metadata.name' "$rendered" | rg -v '^(---)?$' | wc -l)" -ne 3 ]]; then
  echo "Expected two pilot classes and one production class." >&2
  exit 1
fi

if rg -q '^kind: Secret$' "$rendered"; then
  echo "The upstream Helm chart must not generate credentials." >&2
  exit 1
fi

driver_names="$(yq -r 'select(.kind == "CSIDriver") | .metadata.name' "$rendered" | rg -v '^(---)?$')"
if [[ "$driver_names" != "csi.truenas.io" ]]; then
  echo "Unexpected CSI driver name(s): $driver_names" >&2
  exit 1
fi

echo "PASS: TrueNAS CSI pilot and production classes preserve TLS, ESO, non-default Retain and NFS boundaries."
