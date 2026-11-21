#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Use example-only values. CI must not read the private source.
export BASE_DOMAIN=example.invalid
export NAS_HOST_IP=192.0.2.2
export GARAGE_ENDPOINT_URL=https://192.0.2.2:9443
export LONGHORN_BACKUP_TARGET=nfs://192.0.2.2:/mnt/example/backups
export LONGHORN_INITIATOR_CIDR_1=198.51.100.1/32
export LONGHORN_INITIATOR_CIDR_2=198.51.100.2/32
export LONGHORN_INITIATOR_CIDR_3=198.51.100.3/32
export TRUENAS_NFS_CLIENT_HOSTS=192.0.2.12,192.0.2.13,192.0.2.14
export METALLB_SHARED_RANGE=192.0.2.201-192.0.2.240
export TRAEFIK_LAN_IP=192.0.2.241
export TRAEFIK_PUBLIC_IP=192.0.2.244
export MUMBLE_LB_IP=192.0.2.202
export VALHEIM_LB_IP=192.0.2.203
export VALHEIM2_LB_IP=192.0.2.204
export ACME_CONTACT_EMAIL=operator@example.invalid
export CONTROL01_TAILNET_FQDN=control.example.invalid

# Check every reconciliation owner before consuming private network inputs.
owners=(
  kubernetes/applications/immich/ks.yaml
  kubernetes/applications/matrix/ks.yaml
  kubernetes/infrastructure/authentik/ks.yaml
  kubernetes/infrastructure/truenas-csi/ks.yaml
  kubernetes/infrastructure/longhorn/ks.yaml
  kubernetes/infrastructure/traefik/ks.yaml
  kubernetes/infrastructure/cert-manager/config-ks.yaml
  kubernetes/infrastructure/metallb/config-ks.yaml
  kubernetes/infrastructure/tailscale/config-ks.yaml
  kubernetes/infrastructure/external-services/ks.yaml
  kubernetes/applications/mumble/ks.yaml
  kubernetes/applications/valheim/ks.yaml
)

for owner in "${owners[@]}"; do
  yq -e '
    .spec.postBuild.substituteFrom[0].kind == "ConfigMap" and
    .spec.postBuild.substituteFrom[0].name == "homelab-private-vars" and
    ([.spec.dependsOn[] | select(.name == "homelab-private-config")] | length) == 1
  ' "$repo_root/$owner" >/dev/null
  path="$(yq -r '.spec.path' "$repo_root/$owner")"
  kubectl kustomize "$repo_root/${path#./}" > "$tmpdir/raw"
  flux envsubst --strict < "$tmpdir/raw" > "$tmpdir/rendered"
  yq eval-all 'true' "$tmpdir/rendered" >/dev/null
done

contracts=(
  'GARAGE_ENDPOINT_URL|kubernetes/applications/immich/app/postgres-objectstore.yaml'
  'GARAGE_ENDPOINT_URL|kubernetes/applications/matrix/app/postgres-objectstore.yaml'
  'GARAGE_ENDPOINT_URL|kubernetes/infrastructure/authentik/app/postgres-objectstore.yaml'
  'NAS_HOST_IP|kubernetes/infrastructure/truenas-csi/app/helmrelease.yaml'
  'TRUENAS_NFS_CLIENT_HOSTS|kubernetes/infrastructure/truenas-csi/app/helmrelease.yaml'
  'LONGHORN_BACKUP_TARGET|kubernetes/infrastructure/longhorn/app/helmrelease.yaml'
  'LONGHORN_INITIATOR_CIDR_1|kubernetes/infrastructure/longhorn/app/helmrelease.yaml'
  'LONGHORN_INITIATOR_CIDR_2|kubernetes/infrastructure/longhorn/app/helmrelease.yaml'
  'LONGHORN_INITIATOR_CIDR_3|kubernetes/infrastructure/longhorn/app/helmrelease.yaml'
  'TRAEFIK_LAN_IP|kubernetes/infrastructure/traefik/app/helmrelease.yaml'
  'TRAEFIK_PUBLIC_IP|kubernetes/infrastructure/traefik/app/helmrelease.yaml'
  'METALLB_SHARED_RANGE|kubernetes/infrastructure/metallb/config/ipaddresspool.yaml'
  'TRAEFIK_LAN_IP|kubernetes/infrastructure/metallb/config/ipaddresspool-traefik.yaml'
  'TRAEFIK_PUBLIC_IP|kubernetes/infrastructure/metallb/config/ipaddresspool-traefik-public.yaml'
  'NAS_HOST_IP|kubernetes/infrastructure/external-services/app/truenas/endpointslice.yaml'
  'CONTROL01_TAILNET_FQDN|kubernetes/infrastructure/tailscale/config/service.yaml'
  'ACME_CONTACT_EMAIL|kubernetes/infrastructure/cert-manager/config/clusterissuer.yaml'
  'MUMBLE_LB_IP|kubernetes/applications/mumble/app/helmrelease.yaml'
  'VALHEIM_LB_IP|kubernetes/applications/valheim/app/helmrelease.yaml'
  'VALHEIM2_LB_IP|kubernetes/applications/valheim/app/worlds/brave-new-world/helmrelease.yaml'
)

files=()
for contract in "${contracts[@]}"; do
  IFS='|' read -r key path <<< "$contract"
  files+=("$repo_root/$path")
  grep -Fq "\${$key}" "$repo_root/$path" || {
    echo "Missing private input reference: $path / $key" >&2
    exit 1
  }
done

# Real infrastructure addresses, contacts and Tailnet FQDNs belong in private Git.
if rg -n '(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}|[A-Za-z0-9-]+\.ts\.net)' "${files[@]}"; then
  echo 'Found environment-specific literal in private configuration consumer.' >&2
  exit 1
fi

echo 'PASS: private network and contact consumers render from synthetic inputs.'
