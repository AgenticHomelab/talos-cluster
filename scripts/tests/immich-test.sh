#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
# Offline contract: no API server, credential decryption or chart downloads.
test -f kubernetes/applications/immich/config/helmrelease.yaml
command -v yq >/dev/null 2>&1 || { printf 'Required command not found: yq\n' >&2; exit 1; }
{
  kubectl kustomize kubernetes/applications/immich
  printf '\n---\n'
  kubectl kustomize kubernetes/applications/immich/app
  printf '\n---\n'
  kubectl kustomize kubernetes/applications/immich/config
} | yq -o=json -I=0 '.' | python3 -c '
import json, sys
objects = [json.loads(line) for line in sys.stdin if line.strip()]
objects = [o for o in objects if o]
def get(kind, name):
    return next(o for o in objects if o["kind"] == kind and o["metadata"]["name"] == name)
assert not any(o["kind"] == "PersistentVolume" and o["metadata"]["name"] == "immich-media-static-pv" for o in objects)
assert not any(o["kind"] == "PersistentVolumeClaim" and o["metadata"]["name"] == "immich-media" for o in objects)
target = get("PersistentVolumeClaim", "immich-media-truenas")
assert target["spec"]["storageClassName"] == "truenas-csi-production-retain"
assert target["spec"]["accessModes"] == ["ReadWriteMany"]
assert target["spec"]["resources"]["requests"]["storage"] == "2Ti"
assert target["metadata"]["annotations"]["kustomize.toolkit.fluxcd.io/prune"] == "disabled"
assert "volumeName" not in target["spec"]
assert get("Cluster", "immich-postgres")["metadata"]["annotations"]["kustomize.toolkit.fluxcd.io/prune"] == "disabled"
primary = get("Kustomization", "immich")["spec"]
config = get("Kustomization", "immich-config")["spec"]
assert {d["name"] for d in primary["dependsOn"]} == {"barman-cloud", "cloudnative-pg", "longhorn", "truenas-csi", "external-secrets-config", "homelab-private-config"}
assert {d["name"] for d in config["dependsOn"]} == {"immich", "traefik", "cert-manager-config", "external-dns", "homelab-private-config"}
# Both reconciliation units are enabled; offline rendering does not prove runtime health.
assert primary.get("suspend") is False, "CNPG/Barman stage must remain active"
assert config.get("suspend") is False, "Application reconciliation unit must remain enabled"
assert primary["wait"] and "decryption" not in primary
assert config["wait"] and "decryption" not in config
assert not any(o["kind"] == "Kustomization" and o["metadata"]["name"] == "immich-secrets" for o in objects)
expected = {
    "immich-postgres-user": ("k8s-immich-immich-postgres-user", "kubernetes.io/basic-auth"),
    "immich-postgres-s3": ("k8s-immich-immich-postgres-s3", "Opaque"),
    "immich-postgres-s3-ca": ("k8s-authentik-authentik-postgres-s3-ca", "Opaque"),
}
for name, (vault_name, secret_type) in expected.items():
    es = get("ExternalSecret", name)
    assert es["metadata"]["namespace"] == "immich"
    spec = es["spec"]
    assert spec["secretStoreRef"] == {"kind": "ClusterSecretStore", "name": "oci-vault"}
    assert spec["target"]["name"] == name
    assert spec["target"]["creationPolicy"] == "Orphan" and spec["target"]["deletionPolicy"] == "Retain"
    assert spec["target"].get("template", {}).get("type", "Opaque") == secret_type
    assert spec["dataFrom"] == [{"extract": {"key": vault_name}}]

cluster = get("Cluster", "immich-postgres")["spec"]
assert cluster["instances"] == 3 and cluster["affinity"]["podAntiAffinityType"] == "required"
assert cluster["storage"]["storageClass"] == "longhorn"
assert "18.6-minimal-trixie@sha256:" in cluster["imageName"]
assert cluster["bootstrap"]["initdb"]["secret"]["name"] == "immich-postgres-user"
assert cluster["bootstrap"]["initdb"]["owner"] == "immich"
extensions = {e["name"]: e for e in cluster["postgresql"]["extensions"]}
assert set(extensions) == {"pgvector", "vchord"}
assert extensions["vchord"]["dynamic_library_path"] == ["usr/lib/postgresql/18/lib"]
assert extensions["vchord"]["extension_control_path"] == ["usr/share/postgresql/18"]
assert cluster["postgresql"]["shared_preload_libraries"] == ["vchord.so"]
assert cluster["plugins"][0]["parameters"]["barmanObjectName"] == "immich-postgres-backups"
store = get("ObjectStore", "immich-postgres-backups")["spec"]
assert store["configuration"]["destinationPath"] == "s3://immich-postgres-backups/"
assert store["retentionPolicy"] == "30d"
assert store["configuration"]["s3Credentials"]["accessKeyId"]["name"] == "immich-postgres-s3"
backup = get("ScheduledBackup", "immich-postgres-daily")["spec"]
assert backup["method"] == "plugin" and backup["immediate"] is False
assert get("NetworkPolicy", "namespace-isolation")["spec"] == {
    "podSelector": {}, "policyTypes": ["Ingress"], "ingress": [{"from": [{"podSelector": {}}]}]}
assert get("NetworkPolicy", "allow-traefik-ingress")["spec"]["podSelector"]["matchLabels"] == {
    "app.kubernetes.io/name": "server", "app.kubernetes.io/instance": "immich"}
hr = get("HelmRelease", "immich")["spec"]
assert hr["chartRef"] == {"kind": "OCIRepository", "name": "immich"}
assert hr["upgrade"]["remediation"] == {"retries": 0, "remediateLastFailure": False}
assert hr["valuesFrom"] == [{"kind": "ConfigMap", "name": "immich-values", "valuesKey": "values.yaml"}]
assert get("ConfigMap", "immich-values")["metadata"]["labels"]["reconcile.fluxcd.io/watch"] == "Enabled"
assert get("OCIRepository", "immich")["spec"]["ref"]["digest"].startswith("sha256:")
print("PASS: Immich storage, database/backup inputs and enabled Flux reconciliation contract")
'
BASE_DOMAIN=example.invalid flux envsubst --strict < kubernetes/applications/immich/config/values.yaml | yq -o=json -I=0 '.' | python3 -c '
import json, sys
v = json.load(sys.stdin)
# Pin the intended media cutover; legacy NFS claim is no longer declared in Git.
assert v["immich"]["persistence"]["library"]["existingClaim"] == "immich-media-truenas"
components = ("server", "machine-learning", "valkey")
for component in components:
    assert v[component]["enabled"]
    ctl = v[component]["controllers"]["main"]
    assert ctl["replicas"] == 1 and ctl["strategy"] == "Recreate"
    assert "@sha256:" in ctl["containers"]["main"]["image"]["tag"]
    sc = ctl.get("pod", {}).get("securityContext", v["defaultPodOptions"]["securityContext"])
    assert sc["runAsNonRoot"] and sc["runAsUser"] == sc["runAsGroup"] == 1000
    assert sc["seccompProfile"] == {"type": "RuntimeDefault"}
assert "fsGroup" not in v["defaultPodOptions"]["securityContext"]
a, b = [v[c]["controllers"]["main"]["containers"]["main"]["image"]["tag"].split("@")[0] for c in components[:2]]
assert a == b and a.startswith("v")
annotations = v["server"]["ingress"]["main"]["annotations"]
assert annotations["network-exposure"] == "internal"
assert annotations["traefik.ingress.kubernetes.io/router.entrypoints"] == "websecure"
assert annotations["external-dns.kubernetes.io/target"] == "traefik.example.invalid"
for component, volume in (("machine-learning", "cache"), ("valkey", "data")):
    pvc = v[component]["persistence"][volume]
    assert pvc["type"] == "persistentVolumeClaim" and pvc["storageClass"] == "longhorn"
    assert pvc["accessMode"] == "ReadWriteOnce" and pvc["retain"]
assert v["server"]["controllers"]["main"]["containers"]["main"]["env"]["DB_PASSWORD"] == {
    "valueFrom": {"secretKeyRef": {"name": "immich-postgres-user", "key": "password"}}}
print("PASS: matching Immich releases, rootless identities, private ingress and persistent cache/queues")
'
