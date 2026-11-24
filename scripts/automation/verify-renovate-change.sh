#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
policy="${HOMELAB_VERIFICATION_POLICY_FILE:-$repo_root/docs/verification-policy.yaml}"
revision=
plan_only=false
changed_files_path=
declare -a changed_files=()

usage() {
  cat <<'USAGE'
Usage: verify-renovate-change.sh --revision SHA (--changed-file PATH ... | --changed-files FILE) [--plan-only] [--policy PATH]

Fail-closed, read-only repository-wide post-merge verifier for canonical Renovate
dependency changes. It binds evidence to one exact merged Git SHA, derives Flux
reconciliation targets from the repository registry, and never mutates GitHub,
Flux, Kubernetes, Talos, or Omni.
USAGE
}

while (($#)); do
  case "$1" in
    --revision)
      [[ $# -ge 2 ]] || { echo "--revision requires a SHA" >&2; exit 2; }
      revision="$2"; shift 2 ;;
    --changed-file)
      [[ $# -ge 2 ]] || { echo "--changed-file requires a repository path" >&2; exit 2; }
      changed_files+=("$2"); shift 2 ;;
    --changed-files)
      [[ $# -ge 2 ]] || { echo "--changed-files requires a file path" >&2; exit 2; }
      changed_files_path="$2"; shift 2 ;;
    --plan-only)
      plan_only=true; shift ;;
    --policy)
      [[ $# -ge 2 ]] || { echo "--policy requires a path" >&2; exit 2; }
      policy="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2 ;;
  esac
done

[[ "$revision" =~ ^[0-9a-f]{40}$ ]] || {
  echo "--revision must be an exact lowercase 40-character Git SHA" >&2
  exit 2
}

if [[ -n "$changed_files_path" ]]; then
  [[ -f "$changed_files_path" && ! -L "$changed_files_path" ]] || {
    echo "changed-files input must be a regular non-symlink file: $changed_files_path" >&2
    exit 2
  }
  mapfile -t file_list < "$changed_files_path"
  changed_files+=("${file_list[@]}")
fi

((${#changed_files[@]} > 0)) || {
  echo "at least one changed repository path is required" >&2
  exit 2
}

for command in bash find jq sort yq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

"$repo_root/scripts/validate-verification-policy.sh" --policy "$policy" >/dev/null
policy_json="$(yq -o=json -I=0 '.' "$policy")"
registry="$repo_root/kubernetes/kustomization.yaml"

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
  [[ -f "$repo_root/$path" && ! -L "$repo_root/$path" ]] || {
    echo "changed path must exist as a regular non-symlink repository file after merge: $path" >&2
    exit 1
  }
done

mapfile -t registered_units < <(yq -r '.resources[]' "$registry" | sort -u)
((${#registered_units[@]} > 0)) || {
  echo "reconciliation unit registry is empty" >&2
  exit 1
}
for unit in "${registered_units[@]}"; do
  [[ "$unit" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?/[a-z0-9]([-a-z0-9]*[a-z0-9])?$ && -d "$repo_root/kubernetes/$unit" ]] || {
    echo "invalid reconciliation unit registry entry: $unit" >&2
    exit 1
  }
done

unit_is_registered() {
  local wanted="$1" candidate
  for candidate in "${registered_units[@]}"; do
    [[ "$candidate" == "$wanted" ]] && return 0
  done
  return 1
}

verification_class=repository-only
flux_global=false
declare -A selected_units=()
declare -A representative_path=()

for path in "${normalized_files[@]}"; do
  if [[ "$path" =~ ^kubernetes/(clusters|flux)(/|$) ]]; then
    # Flux control-plane paths are never application units; verify globally.
    flux_global=true
  elif [[ "$path" =~ ^kubernetes/([^/]+)/([^/]+)/.+$ ]]; then
    category="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    [[ "$category" =~ ^(applications|infrastructure|observability)$ ]] || {
      echo "changed Kubernetes path is not under an allowed unit category: $path" >&2
      exit 1
    }
    unit_is_registered "$unit" || {
      echo "changed Kubernetes app path belongs to an unregistered reconciliation unit: $path" >&2
      exit 1
    }
    selected_units["$unit"]=1
    representative_path["$unit"]="${representative_path[$unit]:-$path}"
  elif [[ "$path" == kubernetes/* ]]; then
    flux_global=true
  fi
done

if [[ "$flux_global" == true ]]; then
  verification_class=flux-global
  selected_units=()
  for unit in "${registered_units[@]}"; do
    selected_units["$unit"]=1
  done
elif ((${#selected_units[@]} > 0)); then
  verification_class=flux-unit
fi

mapfile -t unit_names < <(printf '%s\n' "${!selected_units[@]}" | awk 'NF' | sort -u)

declare -A flux_target_seen=()
declare -A helm_target_seen=()
declare -a flux_targets=()
declare -a helm_targets=()

collect_unit_targets() {
  local unit="$1" unit_root="$repo_root/kubernetes/$unit"
  local file name namespace target_path source_kind source_name has_decryption ref
  local unit_flux_count=0
  mapfile -t top_level_yaml < <(
    find "$unit_root" -maxdepth 1 -type f \( -name '*.yaml' -o -name '*.yml' \) -print |
      sort
  )
  for file in "${top_level_yaml[@]}"; do
    while IFS=$'\t' read -r name namespace target_path source_kind source_name has_decryption; do
      [[ -n "$name" ]] || continue
      [[ "$name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || {
        echo "Flux Kustomization has an invalid name in $unit: $name" >&2
        return 1
      }
      [[ "$namespace" == flux-system ]] || {
        echo "Flux Kustomization $name is not in flux-system" >&2
        return 1
      }
      [[ "$source_kind" == GitRepository && "$source_name" == flux-system ]] || {
        echo "Flux Kustomization $name references an unsupported GitRepository: $source_kind/$source_name" >&2
        return 1
      }
      [[ "$has_decryption" == false ]] || {
        echo "Flux Kustomization $name unexpectedly declares decryption" >&2
        return 1
      }
      [[ "$target_path" == "./kubernetes/$unit/"* ]] || {
        echo "Flux Kustomization $name escapes reconciliation unit $unit: $target_path" >&2
        return 1
      }
      if [[ -n "${flux_target_seen[$name]:-}" ]]; then
        echo "Flux Kustomization target is not unique: $name" >&2
        return 1
      fi
      flux_target_seen["$name"]="$unit"
      flux_targets+=("$name")
      unit_flux_count=$((unit_flux_count + 1))
    done < <(
      yq -r '
        select(.apiVersion == "kustomize.toolkit.fluxcd.io/v1" and .kind == "Kustomization")
        | [
            (.metadata.name // ""),
            (.metadata.namespace // ""),
            (.spec.path // ""),
            (.spec.sourceRef.kind // ""),
            (.spec.sourceRef.name // ""),
            (.spec | has("decryption"))
          ]
        | @tsv
      ' "$file"
    )
  done
  ((unit_flux_count > 0)) || {
    echo "registered reconciliation unit has no top-level Flux Kustomization: $unit" >&2
    return 1
  }

  mapfile -t recursive_yaml < <(
    find "$unit_root" -type f \( -name '*.yaml' -o -name '*.yml' \) -print |
      sort
  )
  for file in "${recursive_yaml[@]}"; do
    while IFS=$'\t' read -r namespace name; do
      [[ -n "$name" ]] || continue
      [[ "$namespace" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ && "$name" =~ ^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$ ]] || {
        echo "HelmRelease has a missing or invalid namespace/name in $file" >&2
        return 1
      }
      ref="$namespace/$name"
      if [[ -n "${helm_target_seen[$ref]:-}" ]]; then
        echo "HelmRelease target is not unique: $ref" >&2
        return 1
      fi
      helm_target_seen["$ref"]="$unit"
      helm_targets+=("$ref")
    done < <(
      yq -r '
        select(.apiVersion == "helm.toolkit.fluxcd.io/v2" and .kind == "HelmRelease")
        | [(.metadata.namespace // ""), (.metadata.name // "")]
        | @tsv
      ' "$file"
    )
  done
}

for unit in "${unit_names[@]}"; do
  collect_unit_targets "$unit"
done

mapfile -t flux_targets < <(printf '%s\n' "${flux_targets[@]}" | awk 'NF' | sort -u)
mapfile -t helm_targets < <(printf '%s\n' "${helm_targets[@]}" | awk 'NF' | sort -u)

declare -A deep_application=()
if [[ "$verification_class" == flux-unit ]]; then
  for unit in "${unit_names[@]}"; do
    unit_name="${unit##*/}"
    prefix="kubernetes/$unit/"
    mapfile -t matches < <(
      jq -r --arg prefix "$prefix" '
        .spec.verification.applications[]
        | select(.pathPrefix == $prefix)
        | .name
      ' <<<"$policy_json"
    )
    if ((${#matches[@]} > 1)); then
      echo "reconciliation unit has ambiguous deep verification mappings: $unit" >&2
      exit 1
    fi
    if ((${#matches[@]} == 1)); then
      deep_application["$unit"]="${matches[0]}"
    fi
  done
fi

print_plan() {
  echo "revision=$revision"
  echo "verification-class=$verification_class"
  for unit in "${unit_names[@]}"; do
    echo "unit=${unit##*/}"
  done
  for name in "${flux_targets[@]}"; do
    echo "flux-kustomization=$name"
  done
  for ref in "${helm_targets[@]}"; do
    echo "helm-release=$ref"
  done
  for unit in "${unit_names[@]}"; do
    [[ -n "${deep_application[$unit]:-}" ]] || continue
    echo "deep-application=${deep_application[$unit]}"
  done
}

if [[ "$plan_only" == true ]]; then
  print_plan
  exit 0
fi

command -v kubectl >/dev/null 2>&1 || {
  echo "Missing required command: kubectl" >&2
  exit 1
}

source_namespace="$(jq -r '.spec.verification.source.namespace' <<<"$policy_json")"
source_name="$(jq -r '.spec.verification.source.name' <<<"$policy_json")"
timeout_seconds="$(jq -r '.spec.verification.timeoutSeconds' <<<"$policy_json")"
poll_seconds="$(jq -r '.spec.verification.pollSeconds' <<<"$policy_json")"
deadline=$((SECONDS + timeout_seconds))

revision_matches() {
  local actual="$1"
  [[ "$actual" == "$revision" || "$actual" == *"@sha1:$revision" ]]
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
  local name="$1" json expected_revision="$revision"
  json="$(kubectl -n flux-system get kustomization.kustomize.toolkit.fluxcd.io "$name" -o json 2>/dev/null)" || return 1
  jq -e --arg revision "$expected_revision" '
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

wait_until "Flux source reached exact revision $revision" source_is_target
initial_source_revision="$(source_revision_once)"
revision_matches "$initial_source_revision" || {
  echo "Flux source moved before verification started: $initial_source_revision" >&2
  exit 1
}

for name in "${flux_targets[@]}"; do
  wait_until "Flux Kustomization $name applied $revision" kustomization_is_ready "$name"
done
for ref in "${helm_targets[@]}"; do
  wait_until "HelmRelease $ref is Ready" helmrelease_is_ready "$ref"
done

# Existing explicit application mappings remain a stronger optional overlay.
# They are used only for directly changed units, never fabricated for a global
# Kubernetes change.
if [[ "$verification_class" == flux-unit ]]; then
  for unit in "${unit_names[@]}"; do
    [[ -n "${deep_application[$unit]:-}" ]] || continue
    path="${representative_path[$unit]:-}"
    [[ -n "$path" ]] || {
      echo "deep verification mapping has no changed path for unit: $unit" >&2
      exit 1
    }
    if ! bash "$repo_root/scripts/verify-change.sh" \
      --revision "$revision" \
      --changed-file "$path"; then
      echo "deep post-merge verification failed for unit: $unit" >&2
      exit 1
    fi
  done
fi

final_source_revision="$(source_revision_once 2>/dev/null || true)"
if [[ "$final_source_revision" != "$initial_source_revision" ]] || ! revision_matches "$final_source_revision"; then
  echo "Flux source changed while repository-wide evidence was collected; stopping: initial=$initial_source_revision final=${final_source_revision:-unavailable}" >&2
  exit 1
fi

for name in "${flux_targets[@]}"; do
  kustomization_is_ready "$name" || {
    echo "Flux Kustomization became unhealthy during final verification: $name" >&2
    exit 1
  }
done
for ref in "${helm_targets[@]}"; do
  helmrelease_is_ready "$ref" || {
    echo "HelmRelease became unhealthy during final verification: $ref" >&2
    exit 1
  }
done

closing_source_revision="$(source_revision_once 2>/dev/null || true)"
if [[ "$closing_source_revision" != "$initial_source_revision" ]] || ! revision_matches "$closing_source_revision"; then
  echo "Flux source changed during final repository-wide verification; stopping: initial=$initial_source_revision final=${closing_source_revision:-unavailable}" >&2
  exit 1
fi

printf 'PASS: exact revision %s remained stable; repository-wide post-merge verification class %s passed' \
  "$revision" "$verification_class"
if ((${#unit_names[@]} > 0)); then
  printf ' for units: %s' "$(IFS=,; echo "${unit_names[*]##*/}")"
fi
printf '.\n'
