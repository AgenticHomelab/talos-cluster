#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="${HOMELAB_VERIFICATION_POLICY_FILE:-$repo_root/docs/verification-policy.yaml}"
availability_policy="${HOMELAB_AVAILABILITY_POLICY_FILE:-$repo_root/docs/availability-policy.yaml}"
revision=
plan_only=false
changed_files_path=
declare -a changed_files=()

usage() {
  cat <<'USAGE'
Usage: verify-change.sh --revision SHA (--changed-file PATH ... | --changed-files FILE) [--plan-only]
                        [--policy PATH] [--availability-policy PATH]

Fail-closed, read-only post-merge verifier. It waits for the exact merged Git
revision to reach Flux, verifies only explicitly mapped reconciliation units,
checks their workloads and deterministic service probes, then confirms that the
Flux source revision did not move while evidence was collected.
USAGE
}

while (($#)); do
  case "$1" in
    --revision)
      [[ $# -ge 2 ]] || { echo "--revision requires a SHA" >&2; exit 2; }
      revision="$2"
      shift 2
      ;;
    --changed-file)
      [[ $# -ge 2 ]] || { echo "--changed-file requires a repository path" >&2; exit 2; }
      changed_files+=("$2")
      shift 2
      ;;
    --changed-files)
      [[ $# -ge 2 ]] || { echo "--changed-files requires a file path" >&2; exit 2; }
      changed_files_path="$2"
      shift 2
      ;;
    --plan-only)
      plan_only=true
      shift
      ;;
    --policy)
      [[ $# -ge 2 ]] || { echo "--policy requires a path" >&2; exit 2; }
      policy="$2"
      shift 2
      ;;
    --availability-policy)
      [[ $# -ge 2 ]] || { echo "--availability-policy requires a path" >&2; exit 2; }
      availability_policy="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "--revision must be an exact lowercase 40-character Git SHA" >&2
  exit 2
}

if [[ -n "$changed_files_path" ]]; then
  [[ -f "$changed_files_path" ]] || {
    echo "changed-files input not found: $changed_files_path" >&2
    exit 2
  }
  mapfile -t file_list < "$changed_files_path"
  changed_files+=("${file_list[@]}")
fi

((${#changed_files[@]} > 0)) || {
  echo "at least one changed repository path is required" >&2
  exit 2
}

for command in jq yq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

"$repo_root/scripts/validate-verification-policy.sh" \
  --policy "$policy" \
  --availability-policy "$availability_policy" >/dev/null

policy_json="$(yq -o=json -I=0 '.' "$policy")"
availability_json="$(yq -o=json -I=0 '.' "$availability_policy")"

mapfile -t normalized_files < <(
  printf '%s\n' "${changed_files[@]}" |
    awk 'NF' |
    sort -u
)
((${#normalized_files[@]} > 0)) || {
  echo "changed-file input contained no usable repository paths" >&2
  exit 2
}

for path in "${normalized_files[@]}"; do
  [[ "$path" != /* && "$path" != ./* && "$path" != *'..'* && "$path" != *'//' ]] || {
    echo "changed path must be a normalized repository-relative path: $path" >&2
    exit 2
  }
done

declare -a derived_apps=()
for path in "${normalized_files[@]}"; do
  mapfile -t matches < <(
    jq -r --arg path "$path" '
      .spec.verification.applications[]
      | .pathPrefix as $prefix
      | select($path | startswith($prefix))
      | .name
    ' <<<"$policy_json"
  )
  ((${#matches[@]} == 1)) || {
    echo "changed path has no unique post-merge verification mapping: $path" >&2
    exit 1
  }
  derived_apps+=("${matches[0]}")
done
mapfile -t app_names < <(printf '%s\n' "${derived_apps[@]}" | sort -u)

((${#app_names[@]} > 0)) || {
  echo "no post-merge verification targets were derived" >&2
  exit 1
}

print_plan() {
  echo "revision=$revision"
  for app in "${app_names[@]}"; do
    echo "application=$app"
    jq -r --arg app "$app" '
      .spec.verification.applications[]
      | select(.name == $app)
      | .fluxKustomizations[]
      | "flux-kustomization=" + .
    ' <<<"$policy_json"
    jq -r --arg app "$app" '
      .spec.verification.applications[]
      | select(.name == $app)
      | .helmReleases[]
      | "helm-release=" + .
    ' <<<"$policy_json"
    jq -r --arg app "$app" '
      .spec.verification.applications[]
      | select(.name == $app)
      | .services[]
      | "service=" + .
    ' <<<"$policy_json"
  done
}

if [[ "$plan_only" == true ]]; then
  print_plan
  exit 0
fi

for command in curl kubectl; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

needs_tcp=false
for app in "${app_names[@]}"; do
  while IFS= read -r service; do
    probe_type="$(jq -r --arg name "$service" '.services[] | select(.name == $name) | .probe.type' <<<"$availability_json")"
    if [[ "$probe_type" == tcp ]]; then
      needs_tcp=true
    fi
  done < <(
    jq -r --arg app "$app" '.spec.verification.applications[] | select(.name == $app) | .services[]' <<<"$policy_json"
  )
done
if [[ "$needs_tcp" == true ]]; then
  command -v nc >/dev/null 2>&1 || {
    echo "Missing required command for TCP service probe: nc" >&2
    exit 1
  }
fi

source_namespace="$(jq -r '.spec.verification.source.namespace' <<<"$policy_json")"
source_name="$(jq -r '.spec.verification.source.name' <<<"$policy_json")"
timeout_seconds="$(jq -r '.spec.verification.timeoutSeconds' <<<"$policy_json")"
poll_seconds="$(jq -r '.spec.verification.pollSeconds' <<<"$policy_json")"
deadline=$((SECONDS + timeout_seconds))

revision_matches() {
  local actual="$1"
  [[ -n "$actual" && "$actual" == *"$revision"* ]]
}

source_revision_once() {
  kubectl -n "$source_namespace" get gitrepository.source.toolkit.fluxcd.io "$source_name" -o json 2>/dev/null |
    jq -er '.status.artifact.revision | strings | select(length > 0)'
}

wait_until() {
  local label="$1"
  shift
  while :; do
    if "$@"; then
      echo "PASS: $label"
      return 0
    fi
    if ((SECONDS >= deadline)); then
      echo "verification deadline expired while waiting for: $label" >&2
      return 1
    fi
    sleep "$poll_seconds"
  done
}

source_is_target() {
  local actual
  actual="$(source_revision_once 2>/dev/null || true)"
  revision_matches "$actual"
}

kustomization_is_ready() {
  local name="$1" json
  json="$(kubectl -n flux-system get kustomization.kustomize.toolkit.fluxcd.io "$name" -o json 2>/dev/null)" || return 1
  jq -e --arg revision "$revision" '
    (.status.observedGeneration // 0) == .metadata.generation and
    any(.status.conditions[]?; .type == "Ready" and .status == "True") and
    ((.status.lastAppliedRevision // "") | contains($revision))
  ' <<<"$json" >/dev/null
}

helmrelease_is_ready() {
  local reference="$1" namespace name json
  namespace="${reference%%/*}"
  name="${reference#*/}"
  json="$(kubectl -n "$namespace" get helmrelease.helm.toolkit.fluxcd.io "$name" -o json 2>/dev/null)" || return 1
  jq -e '
    (.status.observedGeneration // 0) == .metadata.generation and
    any(.status.conditions[]?; .type == "Ready" and .status == "True")
  ' <<<"$json" >/dev/null
}

workload_is_ready() {
  local service="$1" kind namespace name json
  kind="$(jq -r --arg service "$service" '.services[] | select(.name == $service) | .workload.kind' <<<"$availability_json")"
  namespace="$(jq -r --arg service "$service" '.services[] | select(.name == $service) | .workload.namespace' <<<"$availability_json")"
  name="$(jq -r --arg service "$service" '.services[] | select(.name == $service) | .workload.name' <<<"$availability_json")"

  json="$(kubectl -n "$namespace" get "$kind" "$name" -o json 2>/dev/null)" || return 1
  case "$kind" in
    deployment)
      jq -e '
        (.status.observedGeneration // 0) as $observed
        | (.metadata.generation) as $generation
        | (.spec.replicas // 1) as $desired
        |
        $observed >= $generation and
        $desired >= 1 and
        (.status.updatedReplicas // 0) == $desired and
        (.status.readyReplicas // 0) == $desired and
        (.status.availableReplicas // 0) == $desired and
        (.status.unavailableReplicas // 0) == 0
      ' <<<"$json" >/dev/null
      ;;
    daemonset)
      jq -e '
        (.status.observedGeneration // 0) as $observed
        | (.metadata.generation) as $generation
        | (.status.desiredNumberScheduled // 0) as $desired
        |
        $observed >= $generation and
        $desired >= 1 and
        (.status.updatedNumberScheduled // 0) == $desired and
        (.status.numberReady // 0) == $desired and
        (.status.numberAvailable // 0) == $desired and
        (.status.numberUnavailable // 0) == 0
      ' <<<"$json" >/dev/null
      ;;
    clusters.postgresql.cnpg.io)
      jq -e '
        (.spec.instances // 0) as $desired |
        $desired >= 1 and
        (.status.readyInstances // 0) == $desired and
        .status.phase == "Cluster in healthy state"
      ' <<<"$json" >/dev/null
      ;;
    *)
      return 1
      ;;
  esac
}

service_probe_is_ready() {
  local service="$1" type target host port
  type="$(jq -r --arg service "$service" '.services[] | select(.name == $service) | .probe.type' <<<"$availability_json")"
  target="$(jq -r --arg service "$service" '.services[] | select(.name == $service) | .probe.target' <<<"$availability_json")"
  case "$type" in
    https)
      curl --fail --silent --show-error --location --max-time 10 "$target" >/dev/null 2>&1
      ;;
    workload)
      workload_is_ready "$service"
      ;;
    tcp)
      host="${target%:*}"
      port="${target##*:}"
      [[ -n "$host" && "$port" =~ ^[0-9]+$ ]] || return 1
      nc -z -w 5 "$host" "$port" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

wait_until "Flux source reached exact revision $revision" source_is_target
initial_source_revision="$(source_revision_once)"
revision_matches "$initial_source_revision" || {
  echo "Flux source moved before verification started: $initial_source_revision" >&2
  exit 1
}

for app in "${app_names[@]}"; do
  while IFS= read -r name; do
    wait_until "Flux Kustomization $name applied $revision" kustomization_is_ready "$name"
  done < <(
    jq -r --arg app "$app" '.spec.verification.applications[] | select(.name == $app) | .fluxKustomizations[]' <<<"$policy_json"
  )

  while IFS= read -r reference; do
    [[ -n "$reference" ]] || continue
    wait_until "HelmRelease $reference is Ready" helmrelease_is_ready "$reference"
  done < <(
    jq -r --arg app "$app" '.spec.verification.applications[] | select(.name == $app) | .helmReleases[]' <<<"$policy_json"
  )

  while IFS= read -r service; do
    wait_until "workload for service $service is fully Ready" workload_is_ready "$service"
    wait_until "service probe $service is healthy" service_probe_is_ready "$service"
  done < <(
    jq -r --arg app "$app" '.spec.verification.applications[] | select(.name == $app) | .services[]' <<<"$policy_json"
  )
done

final_source_revision="$(source_revision_once 2>/dev/null || true)"
if [[ "$final_source_revision" != "$initial_source_revision" ]] || ! revision_matches "$final_source_revision"; then
  echo "Flux source changed while post-merge evidence was collected; stopping: initial=$initial_source_revision final=${final_source_revision:-unavailable}" >&2
  exit 1
fi

for app in "${app_names[@]}"; do
  while IFS= read -r name; do
    kustomization_is_ready "$name" || {
      echo "Flux Kustomization became unhealthy during final verification: $name" >&2
      exit 1
    }
  done < <(
    jq -r --arg app "$app" '.spec.verification.applications[] | select(.name == $app) | .fluxKustomizations[]' <<<"$policy_json"
  )
  while IFS= read -r reference; do
    [[ -n "$reference" ]] || continue
    helmrelease_is_ready "$reference" || {
      echo "HelmRelease became unhealthy during final verification: $reference" >&2
      exit 1
    }
  done < <(
    jq -r --arg app "$app" '.spec.verification.applications[] | select(.name == $app) | .helmReleases[]' <<<"$policy_json"
  )
  while IFS= read -r service; do
    workload_is_ready "$service" || {
      echo "workload became unhealthy during final verification: $service" >&2
      exit 1
    }
    service_probe_is_ready "$service" || {
      echo "service probe became unhealthy during final verification: $service" >&2
      exit 1
    }
  done < <(
    jq -r --arg app "$app" '.spec.verification.applications[] | select(.name == $app) | .services[]' <<<"$policy_json"
  )
done

closing_source_revision="$(source_revision_once 2>/dev/null || true)"
if [[ "$closing_source_revision" != "$initial_source_revision" ]] || ! revision_matches "$closing_source_revision"; then
  echo "Flux source changed during final verification; stopping: initial=$initial_source_revision final=${closing_source_revision:-unavailable}" >&2
  exit 1
fi

printf 'PASS: exact revision %s remained stable and scoped post-merge verification passed for: %s\n' \
  "$revision" "$(IFS=,; echo "${app_names[*]}")"
