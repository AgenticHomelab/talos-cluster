#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
# Assert the registered desired state, not merely files in the repository.
# Both the operator and the reviewed shared egress config are now Flux-managed.
render=$(kubectl kustomize kubernetes/infrastructure/tailscale)
[[ $(printf '%s\n' "$render" | yq -N -r 'select(.kind == "Kustomization") | .metadata.name' | sort) ==  ]]
printf '%s\n' "$render" | yq -e 'select(.kind == "Kustomization") | .spec.suspend != true' >/dev/null
[[ $(printf '%s\n' "$render" | yq -N -r '.kind' | sort -u) == $'Kustomization\nNamespace' ]]
config_owner=kubernetes/infrastructure/tailscale/config-ks.yaml
yq -e '.spec.suspend == false and .spec.postBuild.substituteFrom[0].name == "homelab-private-vars"' "$config_owner" >/dev/null
dependencies="$(yq -r '.spec.dependsOn[].name' "$config_owner" | sort)"
expected_dependencies="$(printf '%s\n' homelab-private-config tailscale | sort)"
[[ "$dependencies" == "$expected_dependencies" ]]
kubectl kustomize kubernetes/infrastructure/tailscale/app | yq -e 'select(.kind == "ExternalSecret" and .metadata.name == "operator-oauth") | .metadata.namespace == "tailscale" and .spec.secretStoreRef.kind == "ClusterSecretStore" and .spec.secretStoreRef.name == "oci-vault" and .spec.target.name == "operator-oauth" and .spec.target.creationPolicy == "Orphan" and .spec.target.deletionPolicy == "Retain" and .spec.dataFrom[0].extract.key == "k8s-tailscale-operator-oauth"' >/dev/null
yq -e '.spec.dependsOn[0].name == "external-secrets-config" and (.spec.dependsOn | length) == 1' kubernetes/infrastructure/tailscale/ks.yaml >/dev/null
hr=kubernetes/infrastructure/tailscale/app/helmrelease.yaml
yq -e '.spec.suspend == false and .spec.values.apiServerProxyConfig.mode == "false" and .spec.values.apiServerProxyConfig.allowImpersonation == "false" and .spec.values.ingressClass.enabled == false and (.spec.values | has("oauth") | not) and (.spec | has("valuesFrom") | not)' "$hr" >/dev/null
[[ $(yq -r '.spec.values.proxyConfig.defaultTags' "$hr") == "tag:k8s" ]]
[[ $(yq -r '.spec.values.operatorConfig.defaultTags[0]' "$hr") == "tag:k8s-operator" ]]
config=$(kubectl kustomize kubernetes/infrastructure/tailscale/config)
[[ $(printf '%s\n' "$config" | yq -N -r '.kind' | sort) == $'ProxyGroup\nService' ]]
printf '%s\n' "$config" | yq -e 'select(.kind == "ProxyGroup") | .spec.type == "egress" and .spec.replicas == 2 and (.spec.tags | length) == 1 and .spec.tags[0] == "tag:k8s-egress"' >/dev/null
printf '%s\n' "$config" | yq -e 'select(.kind == "Service") | .spec.type == "ExternalName" and (.spec.ports | length) == 1 and .spec.ports[0].port == 443 and .spec.ports[0].protocol == "TCP" and .metadata.annotations."tailscale.com/tailnet-fqdn" == "${CONTROL01_TAILNET_FQDN}" and .metadata.annotations."tailscale.com/proxy-group" == "talos-home-egress" and .metadata.annotations."kustomize.toolkit.fluxcd.io/ssa" == "IfNotPresent"' >/dev/null
echo "PASS: Tailscale operator and shared egress config enabled, OCI Vault credential delivery and tags scoped."
tailscale\ntailscale-config' ]]
printf '%s\n' "$render" | yq -e 'select(.kind == "Kustomization") | .spec.suspend != true' >/dev/null
[[ $(printf '%s\n' "$render" | yq -N -r '.kind' | sort -u) == $'Kustomization\nNamespace' ]]
config_owner=kubernetes/infrastructure/tailscale/config-ks.yaml
yq -e '.spec.suspend == false and .spec.postBuild.substituteFrom[0].name == "homelab-private-vars"' "$config_owner" >/dev/null
dependencies="$(yq -r '.spec.dependsOn[].name' "$config_owner" | sort)"
expected_dependencies="$(printf '%s\n' homelab-private-config tailscale | sort)"
[[ "$dependencies" == "$expected_dependencies" ]]
yq -e '.spec.decryption.provider == "sops" and .spec.decryption.secretRef.name == "sops-age" and .spec.sourceRef.name == "homelab-secrets" and .spec.path == "./kubernetes/infrastructure/tailscale/app"' kubernetes/infrastructure/tailscale/secrets-ks.yaml >/dev/null
yq -e '.spec.dependsOn[0].name == "tailscale-secrets" and (.spec.dependsOn | length) == 1' kubernetes/infrastructure/tailscale/ks.yaml >/dev/null
hr=kubernetes/infrastructure/tailscale/app/helmrelease.yaml
yq -e '.spec.suspend == false and .spec.values.apiServerProxyConfig.mode == "false" and .spec.values.apiServerProxyConfig.allowImpersonation == "false" and .spec.values.ingressClass.enabled == false and (.spec.values | has("oauth") | not) and (.spec | has("valuesFrom") | not)' "$hr" >/dev/null
[[ $(yq -r '.spec.values.proxyConfig.defaultTags' "$hr") == "tag:k8s" ]]
[[ $(yq -r '.spec.values.operatorConfig.defaultTags[0]' "$hr") == "tag:k8s-operator" ]]
config=$(kubectl kustomize kubernetes/infrastructure/tailscale/config)
[[ $(printf '%s\n' "$config" | yq -N -r '.kind' | sort) == $'ProxyGroup\nService' ]]
printf '%s\n' "$config" | yq -e 'select(.kind == "ProxyGroup") | .spec.type == "egress" and .spec.replicas == 2 and (.spec.tags | length) == 1 and .spec.tags[0] == "tag:k8s-egress"' >/dev/null
printf '%s\n' "$config" | yq -e 'select(.kind == "Service") | .spec.type == "ExternalName" and (.spec.ports | length) == 1 and .spec.ports[0].port == 443 and .spec.ports[0].protocol == "TCP" and .metadata.annotations."tailscale.com/tailnet-fqdn" == "${CONTROL01_TAILNET_FQDN}" and .metadata.annotations."tailscale.com/proxy-group" == "talos-home-egress" and .metadata.annotations."kustomize.toolkit.fluxcd.io/ssa" == "IfNotPresent"' >/dev/null
echo "PASS: Tailscale operator and shared egress config enabled, credentials encrypted and tags scoped."
