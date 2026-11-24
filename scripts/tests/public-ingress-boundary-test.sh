#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
traefik_release="$repo_root/kubernetes/infrastructure/traefik/app/helmrelease.yaml"
metallb_config="$repo_root/kubernetes/infrastructure/metallb/config"
public_pool="$metallb_config/ipaddresspool-traefik-public.yaml"
l2_advertisement="$metallb_config/l2advertisement.yaml"

for command in jq python3 yq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

[[ -f "$public_pool" ]] || {
  echo "missing dedicated public Traefik MetalLB pool" >&2
  exit 1
}

yq -e '
  .kind == "IPAddressPool" and
  .metadata.name == "traefik-public-pool" and
  .metadata.namespace == "metallb-system" and
  (.spec.addresses | length) == 1 and
  .spec.addresses[0] == "${TRAEFIK_PUBLIC_IP}/32" and
  .spec.autoAssign == false
' "$public_pool" >/dev/null || {
  echo "public Traefik must use the approved non-auto-assigned ${TRAEFIK_PUBLIC_IP}/32 pool" >&2
  exit 1
}

yq -e '.spec.ipAddressPools[] | select(. == "traefik-public-pool")' \
  "$l2_advertisement" >/dev/null || {
  echo "public Traefik pool must be included in the LAN L2 advertisement" >&2
  exit 1
}

python3 - "$repo_root" <<'PY'
from pathlib import Path
import json
import subprocess
import sys

root = Path(sys.argv[1])
apps = root / "kubernetes"
annotation = "traefik.ingress.kubernetes.io/router.entrypoints"
expected = {
    "kubernetes/applications/matrix/app/helmrelease.yaml": 3,
    "kubernetes/applications/matrix/app/mas-compat-ingressroute.yaml": 1,
}
actual = {}


def walk(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


for path in apps.rglob("*.yaml"):
    rendered = subprocess.run(
        ["yq", "eval-all", "-o=json", "-I=0", ".", str(path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    count = 0
    for line in rendered.splitlines():
        if not line.strip() or line.strip() == "null":
            continue
        document = json.loads(line)
        for mapping in walk(document):
            annotations = mapping.get("annotations")
            if not isinstance(annotations, dict):
                continue
            entrypoints = annotations.get(annotation)
            if isinstance(entrypoints, str):
                tokens = {item.strip() for item in entrypoints.split(",")}
                if "websecure-pub" in tokens:
                    if tokens != {"websecure-pub"}:
                        raise SystemExit(f"mixed public ingress entrypoints in {path}: {entrypoints}")
                    count += 1
        if document.get("kind") == "IngressRoute":
            entrypoints = document.get("spec", {}).get("entryPoints", [])
            if "websecure-pub" in entrypoints:
                if entrypoints != ["websecure-pub"]:
                    raise SystemExit(f"mixed public IngressRoute entrypoints in {path}: {entrypoints}")
                count += 1
    if count:
        actual[str(path.relative_to(root))] = count

if actual != expected:
    raise SystemExit(
        "websecure-pub route allowlist mismatch: "
        f"expected {expected}, got {actual}"
    )
PY


rendered="${1:?Supply the exact rendered Traefik chart}"
[[ -s "$rendered" ]] || { echo "Rendered Traefik chart is missing" >&2; exit 1; }

yq -o=json -I=0 '.' "$rendered" |
  jq -s -e '
    ([.[] | select(.kind == "Deployment" and .metadata.name == "traefik")] | length) == 1 and
    ([.[] | select(.kind == "Service" and .metadata.name == "traefik")] | length) == 1 and
    ([.[] | select(.kind == "Service" and .metadata.name == "traefik-public")] | length) == 1 and
    ([.[]
      | select(.kind == "Service" and .metadata.name == "traefik")
      | .spec.loadBalancerIP] == ["${TRAEFIK_LAN_IP}"]) and
    ([.[]
      | select(.kind == "Service" and .metadata.name == "traefik")
      | .spec.ports | map(.name) | sort] == [["ssh", "web", "websecure"]]) and
    ([.[]
      | select(.kind == "Service" and .metadata.name == "traefik-public")
      | .spec.loadBalancerIP] == ["${TRAEFIK_PUBLIC_IP}"]) and
    ([.[]
      | select(.kind == "Service" and .metadata.name == "traefik-public")
      | .spec.ports | map({name, port, protocol}) | sort_by(.name)] ==
      [[
        {"name":"web-public", "port":80, "protocol":"TCP"},
        {"name":"websecure-pub", "port":443, "protocol":"TCP"}
      ]]) and
    ([.[]
      | select(.kind == "Deployment" and .metadata.name == "traefik")
      | .spec.template.spec.containers[]
      | select(.name == "traefik")
      | .args]
      | add
      | index("--entryPoints.web-public.http.redirections.entryPoint.to=:443") != null)
  ' >/dev/null || {
  echo "rendered Traefik chart violates the final public/internal Service boundary" >&2
  exit 1
}

echo "PASS: public and internal ingress planes are disjoint in routing and Services"
