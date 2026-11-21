#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
# Offline policy contract; effective authorization through Omni needs a later
# operator-approved credential drill. No API server or kubeconfig is used here.
kubectl kustomize kubernetes/infrastructure/hermes-readonly/app | yq -o=json -I=0 '.' | python3 -c '
import json, sys
objects = [json.loads(line) for line in sys.stdin if line.strip()]
assert len(objects) == 2
role = next(x for x in objects if x["kind"] == "ClusterRole")
binding = next(x for x in objects if x["kind"] == "ClusterRoleBinding")
assert role["metadata"] == {"name": "hermes-readonly"}
assert binding["roleRef"] == {"apiGroup": "rbac.authorization.k8s.io", "kind": "ClusterRole", "name": "hermes-readonly"}
assert binding["subjects"] == [{"apiGroup": "rbac.authorization.k8s.io", "kind": "Group", "name": "hermes-readonly"}]
expected = {
    "": {"nodes", "namespaces", "pods", "services"},
    "apps": {"deployments", "daemonsets", "statefulsets", "replicasets"},
    "batch": {"jobs", "cronjobs"},
    "kustomize.toolkit.fluxcd.io": {"kustomizations"},
    "helm.toolkit.fluxcd.io": {"helmreleases"},
    "source.toolkit.fluxcd.io": {"gitrepositories", "ocirepositories", "helmrepositories", "helmcharts"},
}
permissions = set()
for rule in role["rules"]:
    assert set(rule) == {"apiGroups", "resources", "verbs"}
    assert set(rule["verbs"]) == {"get", "list"}
    assert len(rule["apiGroups"]) == 1
    group = rule["apiGroups"][0]
    assert set(rule["resources"]) == expected[group]
    for resource in rule["resources"]:
        permissions.update((group, resource, verb) for verb in rule["verbs"])
assert len(role["rules"]) == len(expected)
positive = {(g, r, v) for g, resources in expected.items() for r in resources for v in ("get", "list")}
assert permissions == positive
print("PASS: exact read-only RBAC allowlist and non-privileged group binding")
'
