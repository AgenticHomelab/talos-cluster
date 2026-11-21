#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root/kubernetes/infrastructure/snapshot-controller"
sha256sum --check --status upstream.sha256
cd "$repo_root"

# Offline ownership, provenance and least-privilege contract; never contacts an API.
python3 - <<'PY'
import json
import subprocess

unit = "kubernetes/infrastructure/snapshot-controller"


def objects(*args):
    data = subprocess.check_output(list(args))
    result = subprocess.check_output(["yq", "-o=json", "-I=0", "."], input=data)
    return [json.loads(line) for line in result.splitlines() if line.strip()]


crds = objects("kubectl", "kustomize", unit + "/app")
names = {"volumesnapshotclasses", "volumesnapshotcontents", "volumesnapshots"}
assert len(crds) == 3
assert {x["metadata"]["name"] for x in crds} == {
    x + ".snapshot.storage.k8s.io" for x in names
}
for obj in crds:
    assert obj["kind"] == "CustomResourceDefinition"
    assert obj["spec"]["group"] == "snapshot.storage.k8s.io"
    versions = obj["spec"]["versions"]
    assert [v["name"] for v in versions if v["served"]] == ["v1"]
    assert [v["name"] for v in versions if v["storage"]] == ["v1"]

controller = objects("kubectl", "kustomize", unit + "/config")
expected = {
    ("ServiceAccount", "snapshot-controller"),
    ("ClusterRole", "snapshot-controller-runner"),
    ("ClusterRoleBinding", "snapshot-controller-role"),
    ("Role", "snapshot-controller-leaderelection"),
    ("RoleBinding", "snapshot-controller-leaderelection"),
    ("Deployment", "snapshot-controller"),
}
assert len(controller) == len(expected)
assert {(x["kind"], x["metadata"]["name"]) for x in controller} == expected
for obj in controller:
    assert obj["metadata"].get("namespace") == (
        None if obj["kind"].startswith("Cluster") else "kube-system"
    )
    if obj["kind"].endswith("RoleBinding"):
        assert obj["subjects"] == [{
            "kind": "ServiceAccount", "name": "snapshot-controller", "namespace": "kube-system"
        }]

role = next(x for x in controller if x["kind"] == "ClusterRole")
permissions = {}
for rule in role["rules"]:
    for group in rule["apiGroups"]:
        for resource in rule["resources"]:
            permissions.setdefault((group, resource), set()).update(rule["verbs"])
read = {"get", "list", "watch"}
assert permissions == {
    ("", "persistentvolumes"): read,
    ("", "persistentvolumeclaims"): read | {"update"},
    ("", "events"): {"list", "watch", "create", "update", "patch"},
    ("snapshot.storage.k8s.io", "volumesnapshotclasses"): read,
    ("snapshot.storage.k8s.io", "volumesnapshotcontents"): read | {"create", "update", "delete", "patch"},
    ("snapshot.storage.k8s.io", "volumesnapshotcontents/status"): {"patch"},
    ("snapshot.storage.k8s.io", "volumesnapshots"): read | {"create", "update", "delete", "patch"},
    ("snapshot.storage.k8s.io", "volumesnapshots/status"): {"update", "patch"},
}
lease = next(x for x in controller if x["kind"] == "Role")
assert lease["rules"] == [{
    "apiGroups": ["coordination.k8s.io"], "resources": ["leases"],
    "verbs": ["get", "watch", "list", "delete", "update", "create"]
}]
deployment = next(x for x in controller if x["kind"] == "Deployment")
assert deployment["spec"]["replicas"] == 2
assert deployment["spec"]["minReadySeconds"] == 35
pod = deployment["spec"]["template"]["spec"]
assert pod["serviceAccountName"] == "snapshot-controller"
assert len(pod["containers"]) == 1
container = pod["containers"][0]
assert container["image"] == (
    "registry.k8s.io/sig-storage/snapshot-controller:v8.6.0@sha256:"
    "81e79f205083f105e573ba2ebfe5964ede7f69a154e8627f53ebbbccd3ed9f70"
)
assert container["args"] == [
    "--v=5", "--leader-election=true", "--feature-gates=CSIVolumeGroupSnapshot=false"
]
assert not pod.get("volumes")

registry = objects("kubectl", "kustomize", unit)
assert len(registry) == 2
by_name = {x["metadata"]["name"]: x for x in registry}
api = by_name["snapshot-controller-crds"]["spec"]
assert api["wait"] is True and api["prune"] is False
assert api["path"] == "./" + unit + "/app"
config = by_name["snapshot-controller"]["spec"]
assert config["wait"] is True and config["prune"] is True
assert config["path"] == "./" + unit + "/config"
assert config["dependsOn"] == [{"name": "snapshot-controller-crds"}]
assert all(x["metadata"]["namespace"] == "flux-system" for x in registry)
print("PASS: pinned standard snapshot APIs, single common controller, scoped RBAC and CRD-first Flux ordering")
PY
