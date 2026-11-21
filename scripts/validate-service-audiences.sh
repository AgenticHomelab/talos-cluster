#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
apps_root="${1:-$repo_root/kubernetes/applications}"
infrastructure_root="${2:-$repo_root/kubernetes/infrastructure}"
observability_root="${3:-$repo_root/kubernetes/observability}"
allowed='^(public|internal|port-forward)$'
failures=0

command -v yq >/dev/null 2>&1 || {
  echo "Missing required command: yq" >&2
  exit 1
}

validate_web_entrypoints() {
  local file="$1" marker="$2" audience="$3" entrypoints="$4"
  entrypoints="${entrypoints//[[:space:]]/}"

  case "$audience" in
    public)
      if [[ "$entrypoints" != websecure-pub ]]; then
        echo "FAIL: $file $marker public web route must use only the public HTTPS plane, got '$entrypoints'" >&2
        failures=$((failures + 1))
      fi
      ;;
    internal)
      if [[ "$entrypoints" != websecure ]]; then
        echo "FAIL: $file $marker internal web route must use only the internal HTTPS plane, got '$entrypoints'" >&2
        failures=$((failures + 1))
      fi
      ;;
    port-forward)
      echo "FAIL: $file $marker port-forward resource must not declare a web ingress entrypoint" >&2
      failures=$((failures + 1))
      ;;
  esac
}

while IFS= read -r file; do
  while IFS=$'\t' read -r marker audience; do
    [[ -n "$marker" ]] || continue
    if [[ ! "$audience" =~ $allowed ]]; then
      echo "FAIL: $file exposure marker '$marker' has invalid or missing Service Audience '$audience'" >&2
      failures=$((failures + 1))
    fi
  done < <(
    yq -r '
      ..
      | select(tag == "!!map")
      | select(has("annotations"))
      | .annotations as $a
      | select(
          $a."external-dns.kubernetes.io/hostname" or
          $a."external-dns.alpha.kubernetes.io/hostname" or
          $a."cert-manager.io/cluster-issuer" or
          $a."metallb.io/address-pool"
        )
      | [
          ($a."external-dns.kubernetes.io/hostname" // $a."external-dns.alpha.kubernetes.io/hostname" // $a."cert-manager.io/cluster-issuer" // $a."metallb.io/address-pool"),
          ($a."network-exposure" // "")
        ]
      | @tsv
    ' "$file"
  )

  while IFS=$'\t' read -r kind name audience; do
    [[ -n "$kind" ]] || continue
    if [[ ! "$audience" =~ $allowed ]]; then
      echo "FAIL: $file $kind/$name has invalid or missing Service Audience '$audience'" >&2
      failures=$((failures + 1))
    fi
    if [[ "$audience" == "port-forward" ]]; then
      echo "FAIL: $file $kind/$name is exposed but declares port-forward" >&2
      failures=$((failures + 1))
    fi
  done < <(
    yq -r '
      select(
        .kind == "Ingress" or
        .kind == "IngressRoute" or
        .kind == "IngressRouteTCP" or
        .kind == "IngressRouteUDP" or
        (.kind == "Service" and (.spec.type == "LoadBalancer" or .spec.type == "NodePort"))
      )
      | [.kind, .metadata.name, (.metadata.annotations."network-exposure" // "")]
      | @tsv
    ' "$file"
  )

  while IFS=$'\t' read -r audience entrypoints; do
    [[ -n "$audience" && -n "$entrypoints" ]] || continue
    validate_web_entrypoints "$file" "annotated web ingress" "$audience" "$entrypoints"
  done < <(
    yq -r '
      ..
      | select(tag == "!!map")
      | select(has("annotations"))
      | .annotations as $a
      | select(
          $a."network-exposure" and
          $a."traefik.ingress.kubernetes.io/router.entrypoints"
        )
      | [
          $a."network-exposure",
          $a."traefik.ingress.kubernetes.io/router.entrypoints"
        ]
      | @tsv
    ' "$file"
  )

  while IFS=$'\t' read -r name audience entrypoints; do
    [[ -n "$name" ]] || continue
    validate_web_entrypoints "$file" "IngressRoute/$name" "$audience" "$entrypoints"
  done < <(
    yq -r '
      select(.kind == "IngressRoute")
      | [
          .metadata.name,
          (.metadata.annotations."network-exposure" // ""),
          ((.spec.entryPoints // []) | join(","))
        ]
      | @tsv
    ' "$file"
  )
done < <(find "$apps_root" "$infrastructure_root" "$observability_root" -type f -name '*.yaml' ! -name '*.sops.yaml' -print | sort)

if ((failures > 0)); then
  echo "Service Audience validation failed with $failures finding(s)." >&2
  exit 1
fi

echo "PASS: exposed services declare valid audiences and web routes stay on their intended ingress plane"
