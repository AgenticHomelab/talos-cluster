#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
policy="${HOMELAB_VERIFICATION_POLICY_FILE:-$repo_root/docs/verification-policy.yaml}"
availability_policy="${HOMELAB_AVAILABILITY_POLICY_FILE:-$repo_root/docs/availability-policy.yaml}"

usage() {
  cat <<'USAGE'
Usage: validate-verification-policy.sh [--policy PATH] [--availability-policy PATH]

Validate the read-only post-merge verification policy. Supply private policy
paths via the flags or HOMELAB_*_POLICY_FILE environment variables, without accessing GitHub or
the live cluster.
USAGE
}

while (($#)); do
  case "$1" in
    --policy)
      [[ $# -ge 2 ]] || { echo "--policy requires a path" >&2; exit 2; }
      policy="$2"; shift 2 ;;
    --availability-policy)
      [[ $# -ge 2 ]] || { echo "--availability-policy requires a path" >&2; exit 2; }
      availability_policy="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for command in jq yq; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "Missing required command: $command" >&2
    exit 1
  }
done

[[ -f "$policy" ]] || { echo "verification policy not found: $policy" >&2; exit 1; }
[[ -f "$availability_policy" ]] || { echo "availability policy not found: $availability_policy" >&2; exit 1; }

policy_json="$(yq -o=json -I=0 '.' "$policy")"
availability_json="$(yq -o=json -I=0 '.' "$availability_policy")"

jq -e '
  def nonempty_string:
    if type == "string" then length > 0 else false end;
  def unique_nonempty_strings:
    if type != "array" or length == 0 then false
    else length == (unique | length) and all(.[]; nonempty_string)
    end;
  def unique_strings:
    if type != "array" then false
    else length == (unique | length) and all(.[]; nonempty_string)
    end;
  def integer_between($minimum; $maximum):
    if type != "number" then false
    else . >= $minimum and . <= $maximum and floor == .
    end;
  def helm_release_list:
    if type != "array" then false
    else all(.[]; if type == "string" then test("^[a-z0-9]([-a-z0-9.]*[a-z0-9])?/[a-z0-9]([-a-z0-9.]*[a-z0-9])?$") else false end)
    end;
  def valid_application:
    . as $application |
    ($application.name | if type == "string" then test("^[a-z0-9]([-a-z0-9]*[a-z0-9])?$") else false end) and
    ($application.pathPrefix == ("kubernetes/" + $application.category + "/" + $application.name + "/")) and
    ($application.category == "applications" or $application.category == "infrastructure" or $application.category == "observability") and
    ($application.fluxKustomizations | unique_nonempty_strings) and
    ($application.helmReleases | unique_strings) and
    ($application.helmReleases | helm_release_list) and
    ($application.services | unique_nonempty_strings);
  .spec.verification as $v |
  .kind == "VerificationPolicy" and
  (.spec | keys) == ["verification"] and
  $v.source == {"namespace":"flux-system", "name":"flux-system"} and
  ($v.timeoutSeconds | integer_between(60; 1800)) and
  ($v.pollSeconds | integer_between(1; 30)) and
  ($v.applications | type == "array" and length > 0) and
  ($v.applications | map(.name) | unique_nonempty_strings) and
  ($v.applications | map(.pathPrefix) | unique_nonempty_strings) and
  all($v.applications[]; valid_application)
' <<<"$policy_json" >/dev/null || {
  echo "verification policy violates the fail-closed contract: $policy" >&2
  exit 1
}

mapfile -t services < <(jq -r '.spec.verification.applications[].services[]' <<<"$policy_json" | sort -u)
for service in "${services[@]}"; do
  count="$(jq --arg name "$service" '[.services[] | select(.name == $name)] | length' <<<"$availability_json")"
  [[ "$count" == 1 ]] || {
    echo "verification service must exist exactly once in availability policy: $service" >&2
    exit 1
  }

  jq -e --arg name "$service" '
    .services[]
    | select(.name == $name)
    | (.workload != null) and
      (.workload.kind == "deployment" or
       .workload.kind == "daemonset" or
       .workload.kind == "clusters.postgresql.cnpg.io") and
      (.workload.namespace | type == "string" and length > 0) and
      (.workload.name | type == "string" and length > 0) and
      (.probe.type == "https" or .probe.type == "workload" or .probe.type == "tcp") and
      (.probe.target | type == "string" and length > 0)
  ' <<<"$availability_json" >/dev/null || {
    echo "verification service uses an unsupported or incomplete probe contract: $service" >&2
    exit 1
  }
done

echo "PASS: read-only verification targets and service probe contracts are valid."
