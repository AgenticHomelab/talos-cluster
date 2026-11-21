#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
verifier="$repo_root/scripts/verify-change.sh"
revision='1111111111111111111111111111111111111111'
drift_revision='2222222222222222222222222222222222222222'
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

plan="$($verifier --revision "$revision" --changed-file kubernetes/applications/aiostreams/app/helmrelease.yaml --plan-only)"
grep -qx "revision=$revision" <<<"$plan"
grep -qx 'application=aiostreams' <<<"$plan"
grep -qx 'flux-kustomization=aiostreams' <<<"$plan"
grep -qx 'helm-release=aiostreams/aiostreams' <<<"$plan"
grep -qx 'service=aiostreams' <<<"$plan"

if "$verifier" --revision "$revision" --changed-file kubernetes/applications/valheim/app/helmrelease.yaml --plan-only >/dev/null 2>&1; then
  echo 'unmapped UDP application must fail closed' >&2
  exit 1
fi

if "$verifier" --revision "$revision" --changed-file docs/maintenance.md --plan-only >/dev/null 2>&1; then
  echo 'unmapped repository path must fail closed' >&2
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

if [[ "$args" == *' kustomization.kustomize.toolkit.fluxcd.io aiostreams '* ]]; then
  printf '{"metadata":{"generation":1},"status":{"observedGeneration":1,"lastAppliedRevision":"refs/heads/main@sha1:%s","conditions":[{"type":"Ready","status":"True"}]}}\n' "$MOCK_REVISION"
  exit 0
fi

if [[ "$args" == *' helmrelease.helm.toolkit.fluxcd.io aiostreams '* ]]; then
  cat <<'JSON'
{"metadata":{"generation":1},"status":{"observedGeneration":1,"conditions":[{"type":"Ready","status":"True"}]}}
JSON
  exit 0
fi

if [[ "$args" == *' get deployment aiostreams '* ]]; then
  cat <<'JSON'
{"metadata":{"generation":1},"spec":{"replicas":1},"status":{"observedGeneration":1,"updatedReplicas":1,"readyReplicas":1,"availableReplicas":1,"unavailableReplicas":0}}
JSON
  exit 0
fi

echo "unexpected kubectl invocation: $*" >&2
exit 1
MOCK
chmod +x "$mockbin/kubectl"

cat > "$mockbin/curl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$mockbin/curl"

counter="$tmpdir/source-counter"
PATH="$mockbin:$PATH" \
MOCK_REVISION="$revision" \
MOCK_DRIFT_REVISION="$drift_revision" \
MOCK_SOURCE_COUNTER="$counter" \
MOCK_SOURCE_DRIFT_AFTER=999 \
  "$verifier" --revision "$revision" --changed-file kubernetes/applications/aiostreams/app/helmrelease.yaml >/dev/null

rm -f "$counter"
if PATH="$mockbin:$PATH" \
  MOCK_REVISION="$revision" \
  MOCK_DRIFT_REVISION="$drift_revision" \
  MOCK_SOURCE_COUNTER="$counter" \
  MOCK_SOURCE_DRIFT_AFTER=2 \
  "$verifier" --revision "$revision" --changed-file kubernetes/applications/aiostreams/app/helmrelease.yaml >/dev/null 2>&1; then
  echo 'Flux source drift during evidence collection must fail closed' >&2
  exit 1
fi

echo 'PASS: scoped post-merge verification is exact-revision bound and stops on source drift.'
