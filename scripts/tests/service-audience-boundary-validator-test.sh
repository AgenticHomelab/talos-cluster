#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate-service-audiences.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

run_case() {
  local name="$1" expected="$2" content="$3"
  local dir="$tmp/$name"
  local actual
  mkdir -p "$dir"
  printf '%s\n' "$content" > "$dir/resource.yaml"

  if "$validator" "$dir" >/dev/null 2>&1; then
    actual=pass
  else
    actual=fail
  fi

  if [[ "$actual" != "$expected" ]]; then
    echo "case '$name' expected $expected but got $actual" >&2
    "$validator" "$dir" || true
    exit 1
  fi
}

run_case public-valid pass 'apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: public
  annotations:
    network-exposure: public
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: websecure-pub
spec: {}'

run_case public-on-internal fail 'apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: public
  annotations:
    network-exposure: public
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec: {}'

run_case public-dual-bound fail 'apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: public
  annotations:
    network-exposure: public
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: websecure,websecure-pub
spec: {}'

run_case internal-valid pass 'apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: internal
  annotations:
    network-exposure: internal
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec: {}'

run_case internal-on-public fail 'apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: internal
  annotations:
    network-exposure: internal
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: websecure-pub
spec: {}'

run_case public-ingressroute-valid pass 'apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: public-route
  annotations:
    network-exposure: public
spec:
  entryPoints:
    - websecure-pub
  routes: []'

run_case internal-ingressroute-valid pass 'apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: internal-route
  annotations:
    network-exposure: internal
spec:
  entryPoints:
    - websecure
  routes: []'

run_case port-forward-ingress fail 'apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: forbidden
  annotations:
    network-exposure: port-forward
    cert-manager.io/cluster-issuer: letsencrypt-prod
    traefik.ingress.kubernetes.io/router.entrypoints: websecure
spec: {}'

echo "PASS: Service Audience validator rejects cross-plane and port-forward exposure regressions"

# Helm values can declare DNS exposure without a rendered Ingress/Service kind
# or another marker. The active hostname annotation alone must require audience.
run_case current-dns-missing-audience fail 'apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: dns-only
spec:
  values:
    service:
      annotations:
        external-dns.kubernetes.io/hostname: example.invalid'

run_case current-dns-invalid-audience fail 'apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: dns-only
spec:
  values:
    service:
      annotations:
        external-dns.kubernetes.io/hostname: example.invalid
        network-exposure: private'

run_case current-dns-valid-audience pass 'apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: dns-only
spec:
  values:
    service:
      annotations:
        external-dns.kubernetes.io/hostname: example.invalid
        network-exposure: internal'

# Recognize the legacy marker too, so old manifests cannot bypass safety checks.
run_case legacy-dns-missing-audience fail 'apiVersion: v1
kind: ConfigMap
metadata:
  name: legacy
  annotations:
    external-dns.alpha.kubernetes.io/hostname: example.invalid'

# Additional entrypoints must never silently widen either HTTPS plane.
for audience in public internal; do
  entrypoint=websecure
  [[ "$audience" != public ]] || entrypoint=websecure-pub
  for extra in web unknown; do
    run_case "extra-${entrypoint}-${extra}" fail "apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: extra
  annotations:
    network-exposure: $audience
    traefik.ingress.kubernetes.io/router.entrypoints: $entrypoint,$extra
spec: {}"
    run_case "route-extra-${entrypoint}-${extra}" fail "apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: extra
  annotations:
    network-exposure: $audience
spec:
  entryPoints: [$entrypoint, $extra]"
  done
done
run_case unannotated-service fail 'apiVersion: v1
kind: Service
metadata:
  name: exposed
spec:
  type: LoadBalancer'
