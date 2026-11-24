#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
apps_root="$repo_root/kubernetes"
apps_render="$(mktemp)"
matrix_render="$(mktemp)"
authentik_render="$(mktemp)"
element_render="$(mktemp)"
signal_render="$(mktemp)"
whatsapp_render="$(mktemp)"
whatsapp_config="$(mktemp)"
trap 'rm -f "$apps_render" "$matrix_render" "$authentik_render" "$element_render" "$signal_render" "$whatsapp_render" "$whatsapp_config"' EXIT

kubectl kustomize "$apps_root" >"$apps_render"

matrix_path="$(
  yq -r '
    select(.apiVersion == "kustomize.toolkit.fluxcd.io/v1")
    | select(.metadata.name == "matrix")
    | .spec.path
  ' "$apps_render"
)"

if [[ -z "$matrix_path" ]]; then
  echo "FAIL: required Matrix Reconciliation Unit is not registered" >&2
  exit 1
fi

matrix_path="${matrix_path#./}"
if [[ ! -d "$repo_root/$matrix_path" ]]; then
  echo "FAIL: registered Matrix Bridge Platform path does not exist: ./$matrix_path" >&2
  exit 1
fi

kubectl kustomize "$repo_root/$matrix_path" >"$matrix_render"
kubectl kustomize "$apps_root/infrastructure/authentik/app" >"$authentik_render"
kubectl kustomize "$apps_root/applications/matrix-element/app" >"$element_render"
kubectl kustomize "$apps_root/applications/matrix-signal/app" >"$signal_render"
kubectl kustomize "$apps_root/applications/matrix-whatsapp/app" >"$whatsapp_render"

# Evaluate the same native Flux post-build substitution as production, using
# a synthetic domain. Keep the suite independent of private configuration and
# the real homelab domain, including in clean-history public repositories.
for render in "$matrix_render" "$authentik_render" "$element_render" "$signal_render" "$whatsapp_render"; do
  BASE_DOMAIN=example.invalid GARAGE_ENDPOINT_URL=https://192.0.2.2:9443 flux envsubst --strict <"$render" >"$render.substituted"
  mv "$render.substituted" "$render"
done

yq -r 'select(.kind == "ConfigMap" and .metadata.name == "mautrix-whatsapp-config") | .data."config.yaml"' \
  "$whatsapp_render" >"$whatsapp_config"
if [[ ! -s "$matrix_render" ]]; then
  echo "FAIL: registered Matrix Bridge Platform renders no desired state" >&2
  exit 1
fi

require_match() {
  local description="$1" pattern="$2" file="$3"
  grep -Eq "$pattern" "$file" || {
    echo "FAIL: $description" >&2
    return 1
  }
}

validate_identity_contract() {
  local render="$1" apps="$2"
  yq -N -r 'select(.kind == "ConfigMap" and .metadata.name == "synapse-config") | .data."homeserver.yaml"' "$render" |
    yq -e '.server_name == "example.invalid" and .public_baseurl == "https://matrix.example.invalid/"
      and .matrix_authentication_service.enabled == true
      and .enable_registration == false and .allow_guest_access == false' >/dev/null
  yq -N -r 'select(.kind == "ConfigMap" and .metadata.name == "matrix-mas-config") | .data."config.yaml"' "$render" |
    yq -e '.passwords.enabled == false and .http.issuer == "https://matrix-auth.example.invalid/"
      and .matrix.homeserver == "example.invalid"' >/dev/null
  yq -e '
    select(.kind == "HelmRelease" and .metadata.name == "matrix")
    | .spec.values.persistence."mas-secrets".advancedMounts.mas.main[]
    | select(.path == "/run/secrets/mas")
  ' "$render" >/dev/null || {
    echo "FAIL: MAS must mount its encrypted runtime keys" >&2
    return 1
  }
  if yq -e '
    select(.kind == "HelmRelease" and .metadata.name == "matrix")
    | .spec.values.persistence."signal-registration".advancedMounts.mas
  ' "$render" >/dev/null 2>&1; then
    echo "FAIL: MAS must not mount Synapse appservice registrations" >&2
    return 1
  fi
  require_match "Authentik must own the Matrix Users admission group" \
    'Matrix Users' "$apps"
}

validate_discovery_contract() {
  local render="$1" apps="$2" element="$3"
  require_match "server discovery must delegate federation to matrix.example.invalid:443" \
    'matrix\.example\.invalid:443' "$render"
  require_match "client discovery must delegate to https://matrix.example.invalid" \
    'base_url.*https://matrix\.example\.invalid' "$render"
  require_match "the apex must expose only exact Matrix discovery paths" \
    'pathType: Exact' "$render"
  yq -e 'select(.kind == "Kustomization" and .metadata.name == "matrix-element")' "$apps" >/dev/null || {
    echo "FAIL: Element Web must be an independently reconciled Matrix unit" >&2
    return 1
  }
  require_match "Element must discover the permanent example.invalid server name" \
    'default_server_name.*example\.invalid' "$element"
  require_match "Element must be exposed only to the LAN or Tailnet" \
    'network-exposure: internal' "$element"
  require_match "Element must disable custom homeserver URLs" \
    'disable_custom_urls.*true' "$element"
}

validate_exposure_contract() {
  local render="$1"
  require_match "Matrix must be explicitly marked as public" \
    'network-exposure: public' "$render"
  require_match "the public Synapse route must be limited to /_matrix" \
    'path: /_matrix' "$render"
  require_match "legacy Matrix SSO login subpaths must route to MAS" \
    'PathRegexp.*login\(/\.\*\)\?' "$render"
  require_match "legacy Matrix logout and refresh endpoints must route to MAS" \
    'PathRegexp.*logout\|refresh' "$render"
  if grep -Eq 'path: /_synapse|path: /_synapse/admin' "$render"; then
    echo "FAIL: Synapse Admin API must not have a public ingress route" >&2
    return 1
  fi
  if grep -Eq 'name: (adminapi|prometheus)' "$render"; then
    echo "FAIL: MAS admin or metrics resources must not be mounted on its public listener" >&2
    return 1
  fi
}

validate_dependency_contract() {
  local apps="$1"
  for dependency in barman-cloud longhorn cloudnative-pg traefik cert-manager-config external-dns; do
    DEPENDENCY="$dependency" yq -e '
      select(.kind == "Kustomization" and .metadata.name == "matrix")
      | [.spec.dependsOn[].name]
      | contains([strenv(DEPENDENCY)])
    ' "$apps" >/dev/null || {
      echo "FAIL: Matrix reconciliation must depend on $dependency" >&2
      return 1
    }
  done
}

validate_availability_contract() {
  local render="$1"
  yq -e '
    select(.kind == "Cluster" and .metadata.name == "matrix-postgres")
    | .spec.instances == 3
      and .spec.affinity.podAntiAffinityType == "required"
      and .spec.affinity.topologyKey == "kubernetes.io/hostname"
      and .spec.storage.storageClass == "longhorn"
  ' "$render" >/dev/null || {
    echo "FAIL: Matrix PostgreSQL must be a three-instance, hostname-spread Longhorn cluster" >&2
    return 1
  }
  require_match "Synapse media must use a retained 50Gi Longhorn claim" \
    'size: 50Gi' "$render"

}

validate_backup_contract() {
  local render="$1"
  require_match "Matrix PostgreSQL must archive to its Garage bucket" \
    's3://matrix-postgres-backups/' "$render"
  require_match "Matrix PostgreSQL recovery retention must be 30 days" \
    'retentionPolicy: 30d' "$render"
  require_match "Matrix PostgreSQL must have a daily scheduled backup" \
    'name: matrix-postgres-daily' "$render"
  require_match "Matrix Longhorn claims must opt into the default recurring jobs" \
    'recurring-job-group.longhorn.io/default: enabled' "$render"
}
validate_bridge_policy_contract() {
  local apps="$1" matrix="$2" signal="$3" whatsapp="$4"
  yq -e 'select(.kind == "Kustomization" and .metadata.name == "matrix-signal")' "$apps" >/dev/null || {
    echo "FAIL: mautrix-signal must be an independently reconciled unit" >&2
    return 1
  }
  for dependency in matrix cloudnative-pg external-secrets-config; do
    DEPENDENCY="$dependency" yq -e '
      select(.kind == "Kustomization" and .metadata.name == "matrix-signal")
      | [.spec.dependsOn[].name]
      | contains([strenv(DEPENDENCY)])
    ' "$apps" >/dev/null || {
      echo "FAIL: mautrix-signal must depend on $dependency" >&2
      return 1
    }
  done
  yq -N -r 'select(.kind == "ConfigMap" and .metadata.name == "mautrix-signal-config") | .data."config.yaml"' "$signal" |
    yq -e '.bridge.relay.enabled == false and .bridge.permissions."*" == "commands"
      and .bridge.permissions."@antti:example.invalid" == "admin"
      and .provisioning.shared_secret == "disable" and .provisioning.allow_matrix_auth == false
      and .public_media.enabled == false and .direct_media.enabled == false
      and .backfill.max_initial_messages == 50 and .backfill.queue.enabled == false
      and .encryption.allow == true and .encryption.default == true
      and .encryption.require == true and .encryption.appservice == true
      and .encryption.msc4190 == true and .encryption.pickle_key == "__PICKLE_KEY__"
      and .double_puppet.secrets."example.invalid" == "as_token:__DOUBLE_PUPPET_TOKEN__"' >/dev/null
  require_match "Synapse must load the non-exclusive double-puppet appservice" \
    '/run/secrets/appservices/double-puppet-registration.yaml' "$matrix"
  require_match "Synapse must enable appservice transaction extensions for E2EE" \
    'msc3202_transaction_extensions: true' "$matrix"
  require_match "Synapse must push E2EE to-device messages to appservices" \
    'msc2409_to_device_messages_enabled: true' "$matrix"
  yq -e '
    select(.kind == "HelmRelease" and .metadata.name == "mautrix-signal")
    | .spec.values.persistence.config.advancedMounts.bridge.main[0]
    | (.readOnly // false) == false
  ' "$signal" >/dev/null || {
    echo "FAIL: mautrix-signal must be able to persist generated config updates" >&2
    return 1
  }
  if grep -Eq 'kind: Ingress|kind: IngressRoute' "$signal"; then
    echo "FAIL: mautrix-signal privileged endpoints must remain internal" >&2
    return 1
  fi

  yq -e 'select(.kind == "Kustomization" and .metadata.name == "matrix-whatsapp")' "$apps" >/dev/null || {
    echo "FAIL: mautrix-whatsapp must be an independently reconciled unit" >&2
    return 1
  }
  for dependency in matrix cloudnative-pg longhorn external-secrets-config; do
    DEPENDENCY="$dependency" yq -e '
      select(.kind == "Kustomization" and .metadata.name == "matrix-whatsapp")
      | [.spec.dependsOn[].name]
      | contains([strenv(DEPENDENCY)])
    ' "$apps" >/dev/null || {
      echo "FAIL: mautrix-whatsapp must depend on $dependency" >&2
      return 1
    }
  done
  yq -e '
    .network.history_sync.max_initial_conversations == 50
    and .network.history_sync.request_full_sync == false
    and .network.history_sync.full_sync_config.days_limit == 0
    and .network.history_sync.full_sync_config.size_mb_limit == 0
    and .bridge.relay.enabled == false
    and .bridge.relay.allow_bridge == false
    and .bridge.permissions."*" == "commands"
    and .bridge.permissions."@antti:example.invalid" == "admin"
    and .bridge.permissions."@hermes:example.invalid" == "commands"
    and .provisioning.shared_secret == "disable"
    and .provisioning.allow_matrix_auth == false
    and .public_media.enabled == false
    and .direct_media.enabled == false
    and .backfill.enabled == true
    and .backfill.max_initial_messages == 50
    and .backfill.max_catchup_messages == 50
    and .backfill.queue.enabled == false
    and .double_puppet.secrets."example.invalid" == "as_token:__DOUBLE_PUPPET_TOKEN__"
    and .encryption.allow == true
    and .encryption.default == true
    and .encryption.require == true
    and .encryption.appservice == true
    and .encryption.msc4190 == true
    and .encryption.pickle_key == "__PICKLE_KEY__"
  ' "$whatsapp_config" >/dev/null || {
    echo "FAIL: mautrix-whatsapp policy, encryption, identity or bounded-history contract is incomplete" >&2
    return 1
  }
  # Renovate advances mautrix-whatsapp release tags. Validate the pin shape and
  # keep the config-rendering init container locked to the main image instead
  # of coupling this platform contract to one historical release number.
  yq -e '
    select(.kind == "HelmRelease" and .metadata.name == "mautrix-whatsapp")
    | .spec.values
    | .controllers.bridge.containers.main.image as $image
    | select(
      $image.repository == "dock.mau.dev/mautrix/whatsapp"
      and ($image.tag | test("^v[0-9]+\\.[0-9]+(\\.[0-9]+)?$"))
      and .controllers.bridge.initContainers.config.image.repository == $image.repository
      and .controllers.bridge.initContainers.config.image.tag == $image.tag
      and .controllers.bridge.containers.main.command[0] == "/usr/bin/mautrix-whatsapp"
      and .controllers.bridge.containers.main.probes.startup.enabled == true
      and .controllers.bridge.containers.main.probes.readiness.enabled == true
      and .controllers.bridge.containers.main.probes.liveness.enabled == true
      and .controllers.bridge.containers.main.resources.requests.cpu == "100m"
      and .controllers.bridge.containers.main.resources.requests.memory == "128Mi"
      and .controllers.bridge.containers.main.resources.limits.memory == "512Mi"
      and .service.main.type == "ClusterIP"
      and .service.main.publishNotReadyAddresses == true
    )
  ' "$whatsapp" >/dev/null 2>&1 || {
    echo "FAIL: mautrix-whatsapp must use a pinned release image consistently in its init and main containers, with probes, resources and an internal service" >&2
    return 1
  }
  yq -e '
    select(.kind == "HelmRelease" and .metadata.name == "mautrix-whatsapp")
    | [.spec.values.controllers.bridge.initContainers.config.env[].valueFrom.secretKeyRef.name
      | select(. == "mautrix-whatsapp-secrets")]
    | select(length == 5)
  ' "$whatsapp" >/dev/null || {
    echo "FAIL: mautrix-whatsapp init credentials must all come from its existing Secret" >&2
    return 1
  }
  require_match "Synapse must load the WhatsApp application-service registration" \
    '/run/secrets/whatsapp-appservice/whatsapp-registration.yaml' "$matrix"
  yq -e '
    select(.kind == "HelmRelease" and .metadata.name == "matrix")
    | .spec.values.persistence."whatsapp-registration".advancedMounts.synapse.main[0]
    | .path == "/run/secrets/whatsapp-appservice"
      and (has("subPath") | not)
  ' "$matrix" >/dev/null || {
    echo "FAIL: Synapse WhatsApp registration must use a non-nested Secret directory mount" >&2
    return 1
  }
  yq -e '
    select(.kind == "HelmRelease" and .metadata.name == "mautrix-whatsapp")
    | .spec.values.persistence.config.advancedMounts.bridge.main[0]
    | (.readOnly // false) == false
  ' "$whatsapp" >/dev/null || {
    echo "FAIL: mautrix-whatsapp must be able to persist generated config updates" >&2
    return 1
  }
  if grep -Eq 'kind: Ingress|kind: IngressRoute' "$whatsapp"; then
    echo "FAIL: mautrix-whatsapp privileged endpoints must remain internal" >&2
    return 1
  fi
}

# Verify app-local ESO delivery without fetching private credential values.
for bridge in signal whatsapp; do
  render="$signal_render"
  [[ "$bridge" == signal ]] || render="$whatsapp_render"
  BRIDGE="$bridge" yq -e '
    select(.apiVersion == "external-secrets.io/v1" and .kind == "ExternalSecret")
    | select(.metadata.namespace == ("matrix-" + strenv(BRIDGE)))
    | .spec.secretStoreRef.kind == "ClusterSecretStore"
      and .spec.secretStoreRef.name == "oci-vault"
      and .spec.target.name == ("mautrix-" + strenv(BRIDGE) + "-secrets")
      and .spec.target.creationPolicy == "Orphan"
      and .spec.target.deletionPolicy == "Retain"
      and .spec.dataFrom[0].extract.key == ("k8s-matrix-" + strenv(BRIDGE) + "-mautrix-" + strenv(BRIDGE) + "-secrets")
  ' "$render" >/dev/null || {
    echo "FAIL: bridge Secret must reconcile from OCI Vault" >&2
    exit 1
  }
done

validate_identity_contract "$matrix_render" "$authentik_render"
validate_discovery_contract "$matrix_render" "$apps_render" "$element_render"
validate_exposure_contract "$matrix_render"
validate_dependency_contract "$apps_render" "$matrix_render"
validate_availability_contract "$matrix_render"
validate_backup_contract "$matrix_render"
validate_bridge_policy_contract "$apps_render" "$matrix_render" "$signal_render" "$whatsapp_render"

echo "PASS: registered Matrix Bridge Platform renders and satisfies its active contract sections"
