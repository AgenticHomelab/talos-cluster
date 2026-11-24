#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

# Offline public foundation only; no private checkout, API or Secret values.
python3 - <<'PY'
import json
from pathlib import Path
import subprocess

unit = "kubernetes/infrastructure/external-secrets"


def objects(*args):
    rendered = subprocess.check_output(list(args))
    data = subprocess.check_output(["yq", "-o=json", "-I=0", "."], input=rendered)
    return [json.loads(line) for line in data.splitlines() if line.strip()]


registry = objects("yq", ".", "kubernetes/kustomization.yaml")[0]
assert registry["resources"].count("infrastructure/external-secrets") == 1, "register exactly one standard ESO unit"
resources = objects("kubectl", "kustomize", unit)
by_id = {(obj["kind"], obj["metadata"]["name"]): obj for obj in resources}
assert ("Namespace", "external-secrets") in by_id
controller = by_id[("Kustomization", "external-secrets")]
assert controller["metadata"]["namespace"] == "flux-system"
spec = controller["spec"]
assert spec["path"] == "./" + unit + "/app"
assert spec["sourceRef"] == {"kind": "GitRepository", "name": "flux-system"}
assert spec["wait"] is True and spec["prune"] is True

app = objects("kubectl", "kustomize", unit + "/app")
assert {(obj["kind"], obj["metadata"]["name"]) for obj in app} == {
    ("HelmRelease", "external-secrets"), ("HelmRepository", "external-secrets")
}
release = next(obj for obj in app if obj["kind"] == "HelmRelease")
assert release["metadata"]["namespace"] == "external-secrets"
assert release["spec"]["chart"]["spec"] == {
    "chart": "external-secrets", "version": "2.15.0",
    "sourceRef": {"kind": "HelmRepository", "name": "external-secrets", "namespace": "flux-system"}
}
assert release["spec"]["values"]["installCRDs"] is True
repository = next(obj for obj in app if obj["kind"] == "HelmRepository")
assert repository["metadata"]["namespace"] == "flux-system"
assert repository["spec"]["url"] == "https://charts.external-secrets.io"
print("PASS: one app-local ESO unit, upstream chart pin, controller-owned CRDs")

assert set(by_id) == {
    ("Namespace", "external-secrets"), ("Kustomization", "external-secrets"),
    ("Kustomization", "external-secrets-config")
}, "separate controller and private store owners"
config = by_id[("Kustomization", "external-secrets-config")]
assert config["metadata"]["namespace"] == "flux-system"
spec = config["spec"]
assert spec["sourceRef"] == {"kind": "GitRepository", "name": "homelab-secrets"}
assert spec["path"] == "./" + unit + "/config"
assert spec["wait"] is True and spec["prune"] is True
assert {dep["name"] for dep in spec["dependsOn"]} == {"external-secrets", "homelab-private-config"}
assert spec["postBuild"]["substituteFrom"] == [{"kind": "ConfigMap", "name": "homelab-private-vars"}]
assert spec["healthChecks"] == [{
    "apiVersion": "external-secrets.io/v1", "kind": "ClusterSecretStore", "name": "oci-vault"
}]
# wait=true checks all private config objects. Require an ESO-specific Ready
# predicate rather than treating successful CR application as provider readiness.
# Avoid has(status): top-level identifier presence is not a CEL select macro.
assert "has(status)" not in spec["healthCheckExprs"][0]["current"], "use CEL field selection, not a top-level has() identifier"
assert spec["healthCheckExprs"] == [{
    "apiVersion": "external-secrets.io/v1", "kind": "ClusterSecretStore",
    "current": "has(status.conditions) && status.conditions.exists(c, c.type == 'Ready' && c.status == 'True')"
}]
print("PASS: private store source, prerequisites, substitution and fail-closed Ready gate")
workflow = Path(".github/workflows/validate-desired-state.yaml").read_text()
assert '"infrastructure external-secrets"' in workflow, "CI must acquire the new exact upstream chart"
assert 'external-secrets/upstream.sha256' in workflow, "CI must check the reviewed package hash"
print("PASS: CI acquires and verifies the ESO chart input")
PY
