#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
rendered="${1:?usage: external-secrets-chart-test.sh RENDERED_HELM_OUTPUT}"
cd "$repo_root"
# The rendered schema is accepted only alongside the reviewed upstream archive.
(cd "${HELM_CHARTS_DIR:?Supply exact upstream chart archives}" && \
  sha256sum --check --status "$repo_root/kubernetes/infrastructure/external-secrets/upstream.sha256")

python3 - "$rendered" <<'PY'
import json
import subprocess
import sys


def objects(path):
    data = subprocess.check_output(["yq", "-o=json", "-I=0", ".", path])
    return [json.loads(line) for line in data.splitlines() if line.strip()]


render = objects(sys.argv[1])
by_id = {(obj["kind"], obj["metadata"]["name"]): obj for obj in render}
controller = by_id[("Deployment", "external-secrets")]
container = controller["spec"]["template"]["spec"]["containers"][0]
assert container["image"] == "ghcr.io/external-secrets/external-secrets:v2.15.0"
assert container.get("readinessProbe"), "controller readiness must not be inferred from Pod existence"
assert container.get("livenessProbe")
for name in ("external-secrets", "external-secrets-webhook", "external-secrets-cert-controller"):
    deployment = by_id[("Deployment", name)]
    assert deployment["spec"]["template"]["spec"].get("hostNetwork", False) is False
    security = deployment["spec"]["template"]["spec"]["containers"][0]["securityContext"]
    assert security["runAsNonRoot"] is True
    assert security["readOnlyRootFilesystem"] is True
    assert security["allowPrivilegeEscalation"] is False
    assert security["capabilities"]["drop"] == ["ALL"]

role = by_id[("ClusterRole", "external-secrets-controller")]
for rule in role["rules"]:
    assert not set(rule["resources"]) & {"pushsecrets", "pushsecrets/status", "clusterpushsecrets", "clusterpushsecrets/status", "serviceaccounts/token"}, "pull-only UserPrincipal delivery needs neither push nor token minting"

crds = {obj["metadata"]["name"]: obj for obj in render if obj["kind"] == "CustomResourceDefinition"}
assert "pushsecrets.external-secrets.io" not in crds
assert "clusterpushsecrets.external-secrets.io" not in crds
store = crds["clustersecretstores.external-secrets.io"]
assert store["spec"]["scope"] == "Cluster"
version = next(v for v in store["spec"]["versions"] if v["name"] == "v1")
assert version["served"] is True and version["storage"] is True
oracle = version["schema"]["openAPIV3Schema"]["properties"]["spec"]["properties"]["provider"]["properties"]["oracle"]
assert set(oracle["required"]) == {"region", "vault"}
props = oracle["properties"]
assert "UserPrincipal" in props["principalType"]["enum"]
auth = props["auth"]
assert set(auth["required"]) == {"tenancy", "user", "secretRef"}
refs = auth["properties"]["secretRef"]
assert set(refs["required"]) == {"privatekey", "fingerprint"}
for key in ("privatekey", "fingerprint"):
    selector = refs["properties"][key]
    assert selector["properties"]["namespace"]["type"] == "string"
    assert selector["properties"]["name"]["type"] == "string"
    assert selector["properties"]["key"]["type"] == "string"
# No public store, application ExternalSecret or provider credential is rendered.
assert not any(obj["kind"] in {"ClusterSecretStore", "SecretStore", "ExternalSecret", "PushSecret", "ClusterPushSecret"} for obj in render)
print("PASS: pinned upstream render, hardened controllers, pull-only RBAC and v1 Oracle UserPrincipal schema contract")
PY
