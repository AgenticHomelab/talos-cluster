#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
validator="$repo_root/scripts/validate-complete-desired-state.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
git -C "$tmpdir" init -q
git -C "$tmpdir" config user.email test@example.invalid
git -C "$tmpdir" config user.name Test
mkdir -p "$tmpdir/kubernetes/test"
printf 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: baseline\n' >"$tmpdir/baseline.yaml"
git -C "$tmpdir" add baseline.yaml
git -C "$tmpdir" commit -qm baseline

printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: unsafe\n' >"$tmpdir/kubernetes/test/secret.yaml"
if "$validator" --check-repository "$tmpdir" >/dev/null 2>&1; then
  echo "untracked plaintext Secret must fail repository safety" >&2
  exit 1
fi
rm -f "$tmpdir/kubernetes/test/secret.yaml"

# Even synthetic encrypted envelopes and root creation rules are retired.
printf 'kind: Secret\nsops: {}\n' >"$tmpdir/kubernetes/test/secret.sops.yaml"
if "$validator" --check-repository "$tmpdir" >/dev/null 2>&1; then
  echo "retired encrypted delivery must fail repository safety" >&2
  exit 1
fi
rm -f "$tmpdir/kubernetes/test/secret.sops.yaml"
printf 'creation_rules: []\n' >"$tmpdir/.sops.yaml"
if "$validator" --check-repository "$tmpdir" >/dev/null 2>&1; then
  echo "retired creation rules must fail repository safety" >&2
  exit 1
fi
rm -f "$tmpdir/.sops.yaml"

printf 'generated credential\n' >"$tmpdir/kubeconfig-test"
if "$validator" --check-repository "$tmpdir" >/dev/null 2>&1; then
  echo "untracked credential artifact must fail repository safety" >&2
  exit 1
fi
rm -f "$tmpdir/kubeconfig-test"

mkdir -p "$tmpdir/talos/generated"
printf 'generated machine configuration\n' >"$tmpdir/talos/generated/controlplane.yaml"
if "$validator" --check-repository "$tmpdir" >/dev/null 2>&1; then
  echo "untracked generated configuration must fail repository safety" >&2
  exit 1
fi
rm -rf "$tmpdir/talos"

printf 'untracked trailing whitespace  \n' >"$tmpdir/untracked.txt"
if "$validator" --check-repository "$tmpdir" >/dev/null 2>&1; then
  echo "untracked whitespace errors must fail repository safety" >&2
  exit 1
fi
rm -f "$tmpdir/untracked.txt"

printf 'trailing whitespace  \n' >"$tmpdir/staged.txt"
git -C "$tmpdir" add staged.txt
if "$validator" --check-repository "$tmpdir" >/dev/null 2>&1; then
  echo "staged whitespace errors must fail repository safety" >&2
  exit 1
fi

git -C "$tmpdir" commit -qm 'test: committed whitespace defect'
if "$validator" --check-repository "$tmpdir" >/dev/null 2>&1; then
  echo "committed whitespace errors must fail a clean checkout" >&2
  exit 1
fi

echo "PASS: repository safety rejects plaintext, generated credentials and committed whitespace"
