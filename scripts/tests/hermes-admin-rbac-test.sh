#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
kubectl kustomize kubernetes/infrastructure/hermes-admin/app | yq -o=json -I=0 '.' | python3 -c '
import json,sys
objects=[json.loads(line) for line in sys.stdin if line.strip()]
assert len(objects)==1
binding=objects[0]
assert binding["kind"]=="ClusterRoleBinding"
assert binding["metadata"]=={"name":"hermes-admin"}
assert binding["roleRef"]=={"apiGroup":"rbac.authorization.k8s.io","kind":"ClusterRole","name":"cluster-admin"}
assert binding["subjects"]==[{"apiGroup":"rbac.authorization.k8s.io","kind":"Group","name":"hermes-admin"}]
print("PASS: dedicated Hermes administrator group uses the native cluster-admin role")
'
