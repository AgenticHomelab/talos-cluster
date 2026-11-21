#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/automation/verify-renovate-change.sh"
revision='1111111111111111111111111111111111111111'
drift_revision='2222222222222222222222222222222222222222'
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

valheim_plan="$(bash "$verifier" \
  --revision "$revision" \
  --changed-file kubernetes/applications/valheim/app/helmrelease.yaml \
  --plan-only)"
grep -qx "revision=$revision" <<<"$valheim_plan"
grep -qx 'verification-class=flux-unit' <<<"$valheim_plan"
grep -qx 'unit=valheim' <<<"$valheim_plan"
grep -qx 'flux-kustomization=valheim' <<<"$valheim_plan"
grep -qx 'flux-kustomization=valheim-secrets' <<<"$valheim_plan"
expected_valheim_releases=$'helm-release=valheim/valheim\nhelm-release=valheim/valheim2'
actual_valheim_releases="$(grep '^helm-release=' <<<"$valheim_plan")"
if [[ "$actual_valheim_releases" != "$expected_valheim_releases" ]]; then
  echo 'Valheim verification plan does not contain the exact expected HelmReleases' >&2
  exit 1
fi
if grep -q '^deep-application=' <<<"$valheim_plan"; then
  echo 'unmapped unit must not invent a legacy deep verification mapping' >&2
  exit 1
fi

metallb_plan="$(bash "$verifier" \
  --revision "$revision" \
  --changed-file kubernetes/infrastructure/metallb/app/helmrelease.yaml \
  --plan-only)"
grep -qx 'verification-class=flux-unit' <<<"$metallb_plan"
grep -qx 'unit=metallb' <<<"$metallb_plan"
grep -qx 'flux-kustomization=metallb' <<<"$metallb_plan"
grep -qx 'flux-kustomization=metallb-config' <<<"$metallb_plan"

repo_plan="$(bash "$verifier" \
  --revision "$revision" \
  --changed-file .github/workflows/validate-desired-state.yaml \
  --plan-only)"
grep -qx 'verification-class=repository-only' <<<"$repo_plan"
if grep -q '^flux-kustomization=' <<<"$repo_plan"; then
  echo 'repository-only verification must not fabricate Flux unit targets' >&2
  exit 1
fi

global_plan="$(bash "$verifier" \
  --revision "$revision" \
  --changed-file kubernetes/kustomization.yaml \
  --plan-only)"
grep -qx 'verification-class=flux-global' <<<"$global_plan"
grep -qx 'unit=longhorn' <<<"$global_plan"
grep -qx 'unit=valheim' <<<"$global_plan"
grep -qx 'flux-kustomization=longhorn' <<<"$global_plan"
grep -qx 'flux-kustomization=valheim' <<<"$global_plan"

if bash "$verifier" \
  --revision "$revision" \
  --changed-file kubernetes/not-registered/app/example.yaml \
  --plan-only >/dev/null 2>&1; then
  echo 'unregistered reconciliation unit must fail closed' >&2
  exit 1
fi

if bash "$verifier" \
  --revision "$revision" \
  --changed-file ../escape.yaml \
  --plan-only >/dev/null 2>&1; then
  echo 'non-canonical repository path must fail closed' >&2
  exit 1
fi

if rg -n '\b(kubectl|flux|helm|talosctl)\b.*\b(apply|patch|delete|reconcile|resume|suspend|upgrade|reset|drain)\b' "$verifier" >/dev/null; then
  echo 'F5 verifier must remain read-only' >&2
  exit 1
fi

mockbin="$tmpdir/bin"
mkdir -p "$mockbin"
cat > "$mockbin/kubectl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

args=" $* "
if [[ "$args" == *' gitrepository.source.toolkit.fluxcd.io '* ]]; then
  count=0
  if [[ -f "$MOCK_SOURCE_COUNTER" ]]; then
    count="$(cat "$MOCK_SOURCE_COUNTER")"
  fi
  count=$((count + 1))
  printf '%s\n' "$count" > "$MOCK_SOURCE_COUNTER"
  sha="$MOCK_REVISION"
  if ((count > MOCK_SOURCE_DRIFT_AFTER)); then
    sha="$MOCK_DRIFT_REVISION"
  fi
  printf '{"status":{"artifact":{"revision":"refs/heads/main@sha1:%s"}}}\n' "$sha"
  exit 0
fi

if [[ "$args" == *' kustomization.kustomize.toolkit.fluxcd.io valheim '* ||
      "$args" == *' kustomization.kustomize.toolkit.fluxcd.io valheim-secrets '* ]]; then
  printf '{"metadata":{"generation":1},"status":{"observedGeneration":1,"lastAppliedRevision":"refs/heads/main@sha1:%s","conditions":[{"type":"Ready","status":"True"}]}}\n' "$MOCK_REVISION"
  exit 0
fi

if [[ "$args" == *' helmrelease.helm.toolkit.fluxcd.io '* && "$args" == *' -n valheim '* ]]; then
  cat <<'JSON'
{"metadata":{"generation":1},"status":{"observedGeneration":1,"conditions":[{"type":"Ready","status":"True"}]}}
JSON
  exit 0
fi

echo "unexpected kubectl invocation: $*" >&2
exit 1
MOCK
chmod +x "$mockbin/kubectl"

counter="$tmpdir/source-counter"
PATH="$mockbin:$PATH" \
MOCK_REVISION="$revision" \
MOCK_DRIFT_REVISION="$drift_revision" \
MOCK_SOURCE_COUNTER="$counter" \
MOCK_SOURCE_DRIFT_AFTER=999 \
  bash "$verifier" \
    --revision "$revision" \
    --changed-file kubernetes/applications/valheim/app/helmrelease.yaml >/dev/null

rm -f "$counter"
# The first three source reads establish the public and private baselines.
# Drift on the next read, after both baselines have been captured.
drift_output="$tmpdir/source-drift.log"
if PATH="$mockbin:$PATH" \
  MOCK_REVISION="$revision" \
  MOCK_DRIFT_REVISION="$drift_revision" \
  MOCK_SOURCE_COUNTER="$counter" \
  MOCK_SOURCE_DRIFT_AFTER=3 \
  bash "$verifier" \
    --revision "$revision" \
    --changed-file kubernetes/applications/valheim/app/helmrelease.yaml >"$drift_output" 2>&1; then
  echo 'Flux source drift during F5 evidence collection must fail closed' >&2
  exit 1
fi
if ! grep -Fq 'Flux source changed while repository-wide evidence was collected' "$drift_output"; then
  echo 'Expected exact source-drift rejection, not a timeout or unrelated failure' >&2
  exit 1
fi

echo 'PASS: F5 repository-wide verifier derives Flux targets, keeps repository-only evidence honest, and stops on source drift.'
