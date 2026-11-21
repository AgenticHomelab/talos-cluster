#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Domain-qualified private policy keys must not reappear in manifests.
if rg -n --pcre2 '(?:[a-z0-9-]+[.])+[a-z0-9-]+/(?:audience|purpose)' "$repo_root/kubernetes"; then
  echo 'Legacy private-domain policy qualifier remains in Kubernetes manifests.' >&2
  exit 1
fi

# Every domain-bearing reconciliation owner must use the same private source,
# without making private values or real hostnames available to CI.
contracts=(
  'aiostreams|kubernetes/applications/aiostreams/ks.yaml|aiostreams.example.invalid'
  'ebooks|kubernetes/applications/ebooks/ks.yaml|books.example.invalid'
  'immich-config|kubernetes/applications/immich/config-ks.yaml|immich.example.invalid'
  'matrix-element|kubernetes/applications/matrix-element/ks.yaml|chat.example.invalid'
  'matrix-signal|kubernetes/applications/matrix-signal/ks.yaml|example.invalid'
  'matrix-whatsapp|kubernetes/applications/matrix-whatsapp/ks.yaml|example.invalid'
  'matrix|kubernetes/applications/matrix/ks.yaml|matrix.example.invalid'
  'mumble|kubernetes/applications/mumble/ks.yaml|mumble.example.invalid'
  'valheim|kubernetes/applications/valheim/ks.yaml|valheim.example.invalid'
  'vaultwarden|kubernetes/applications/vaultwarden/ks.yaml|vw.example.invalid'
  'whoami|kubernetes/applications/whoami/ks.yaml|whoami.example.invalid'
  'authentik|kubernetes/infrastructure/authentik/ks.yaml|auth.example.invalid'
  'cloudflare-ddns|kubernetes/infrastructure/cloudflare-ddns/ks.yaml|home.example.invalid'
  'external-dns|kubernetes/infrastructure/external-dns/ks.yaml|example.invalid'
  'external-services|kubernetes/infrastructure/external-services/ks.yaml|truenas.example.invalid'
  'truenas-csi|kubernetes/infrastructure/truenas-csi/ks.yaml|truenas-api.example.invalid'
  'alloy|kubernetes/observability/alloy/ks.yaml|metrics.example.invalid'
)

# New noncredential inputs use documentation-only examples in offline CI.
export GARAGE_ENDPOINT_URL=https://192.0.2.2:9443
export NAS_HOST_IP=192.0.2.2
export CLOUDFLARE_DNS_ZONE_ID=00000000000000000000000000000000
export TRUENAS_NFS_CLIENT_HOSTS=192.0.2.12,192.0.2.13,192.0.2.14
export MUMBLE_LB_IP=192.0.2.202
export VALHEIM_LB_IP=192.0.2.203
export VALHEIM2_LB_IP=192.0.2.204

for contract in "${contracts[@]}"; do
  IFS='|' read -r unit owner expected_host <<<"$contract"
  owner="$repo_root/$owner"
  UNIT_NAME="$unit" yq -e '
    .kind == "Kustomization" and
    .metadata.name == strenv(UNIT_NAME) and
    .metadata.namespace == "flux-system" and
    .spec.sourceRef.name == "flux-system" and
    .spec.postBuild.substituteFrom[0].kind == "ConfigMap" and
    .spec.postBuild.substituteFrom[0].name == "homelab-private-vars" and
    ([.spec.postBuild.substituteFrom[]] | length) == 1 and
    ([.spec.dependsOn[] | select(.name == "homelab-private-config")] | length) == 1
  ' "$owner" >/dev/null

  path="$(yq -r '.spec.path' "$owner")"
  kubectl kustomize "$repo_root/${path#./}" >"$tmpdir/raw"
  BASE_DOMAIN=example.invalid flux envsubst --strict <"$tmpdir/raw" >"$tmpdir/rendered"
  grep -Fq "$expected_host" "$tmpdir/rendered" || {
    echo "Expected synthetic hostname missing for $unit" >&2
    exit 1
  }
  if grep -Fq '${BASE_DOMAIN}' "$tmpdir/rendered"; then
    echo "Unsubstituted base domain in $unit" >&2
    exit 1
  fi
  if [[ -n "${HOMELAB_AUDIT_BASE_DOMAIN:-}" ]] &&
    grep -Fiq -- "$HOMELAB_AUDIT_BASE_DOMAIN" "$tmpdir/rendered"; then
    echo "Literal configured base domain remains in $unit" >&2
    exit 1
  fi

  if [[ "$unit" == matrix-signal || "$unit" == matrix-whatsapp ]]; then
    for shell_var in DATABASE_PASSWORD AS_TOKEN HS_TOKEN DOUBLE_PUPPET_TOKEN PICKLE_KEY; do
      printf -v placeholder '$%s' "$shell_var"
      if ! grep -Fq "$placeholder" "$tmpdir/rendered"; then
        echo "Bridge runtime credential reference not preserved: $unit/$shell_var" >&2
        exit 1
      fi
    done
  fi
  if [[ "$unit" == matrix ]]; then
    # These are shell environment variables, not Flux domain variables.
    for shell_var in DATABASE_PASSWORD ENCRYPTION_SECRET; do
      printf -v placeholder '$%s' "$shell_var"
      if ! grep -Fq "$placeholder" "$tmpdir/rendered"; then
        echo "Matrix runtime credential reference not preserved: $shell_var" >&2
        exit 1
      fi
    done
    if env -u BASE_DOMAIN flux envsubst --strict <"$tmpdir/raw" >/dev/null 2>&1; then
      echo "Matrix must fail closed if private base domain is absent" >&2
      exit 1
    fi
  fi
done

echo 'PASS: all domain-bearing Flux units use one private base domain and render with synthetic hosts.'
