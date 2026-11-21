#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
owner="$repo_root/kubernetes/applications/borgwarehouse/ks.yaml"
private_owner="$repo_root/kubernetes/clusters/talos-home/private-config.yaml"
app="$repo_root/kubernetes/applications/borgwarehouse/app"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

yq -e '
  .kind == "Kustomization" and
  .metadata.name == "borgwarehouse" and
  .spec.postBuild.substituteFrom[0].kind == "ConfigMap" and
  .spec.postBuild.substituteFrom[0].name == "homelab-private-vars" and
  ([.spec.postBuild.substituteFrom[]] | length) == 1 and
  ([.spec.dependsOn[] | select(.name == "homelab-private-config")] | length) == 1
' "$owner" >/dev/null

yq -e '
  .kind == "Kustomization" and
  .metadata.name == "homelab-private-config" and
  .metadata.namespace == "flux-system" and
  .spec.path == "./kubernetes/private-config" and
  .spec.sourceRef.kind == "GitRepository" and
  .spec.sourceRef.name == "homelab-secrets"
' "$private_owner" >/dev/null

kubectl kustomize "$app" > "$tmpdir/before.yaml"
BASE_DOMAIN=example.invalid \
  flux envsubst --strict < "$tmpdir/before.yaml" > "$tmpdir/after.yaml"

# The synthetic substitution must preserve identities and every Borg hostname.
yq -e '
  select(.kind == "HelmRelease" and .metadata.name == "borgwarehouse") |
  .metadata.namespace == "borgwarehouse" and
  .spec.values.controllers.main.containers.main.env.FQDN == "borg.example.invalid" and
  .spec.values.controllers.main.containers.main.env.BETTER_AUTH_URL == "https://borg.example.invalid" and
  .spec.values.controllers.main.containers.main.env.NEXTAUTH_URL == "https://borg.example.invalid" and
  .spec.values.ingress.main.annotations."external-dns.kubernetes.io/hostname" == "borg.example.invalid" and
  .spec.values.ingress.main.annotations."external-dns.kubernetes.io/target" == "traefik.example.invalid" and
  .spec.values.ingress.main.hosts[0].host == "borg.example.invalid" and
  .spec.values.ingress.main.tls[0].hosts[0] == "borg.example.invalid"
' "$tmpdir/after.yaml" >/dev/null

# Enabling Flux postBuild must not consume the runtime credential reference.
cron_script="$(yq -r '
  select(.kind == "CronJob" and .metadata.name == "borgwarehouse-maintenance") |
  .spec.jobTemplate.spec.template.spec.containers[0].command[-1]
' "$tmpdir/after.yaml")"
[[ "$(grep -Fc 'Authorization: Bearer $CRONJOB_KEY' <<<"$cron_script")" == 2 ]] || {
  echo 'Both CronJob requests must preserve their runtime credential reference' >&2
  exit 1
}
if grep -Fq '${CRONJOB_KEY}' <<<"$cron_script"; then
  echo 'Unescaped runtime credential may be consumed by Flux substitution' >&2
  exit 1
fi

# Missing private ConfigMap variables must fail closed during local validation.
if env -u BASE_DOMAIN \
  flux envsubst --strict < "$tmpdir/before.yaml" > /dev/null 2>&1; then
  echo 'BorgWarehouse rendering must reject a missing private domain variable' >&2
  exit 1
fi

echo 'PASS: BorgWarehouse private ConfigMap source, substitution and cron authentication are safe.'
