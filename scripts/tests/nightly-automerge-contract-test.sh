#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$repo_root" <<'PY'
import json
from pathlib import Path
import sys

root = Path(sys.argv[1])
config = json.loads((root / "renovate.json").read_text())
assert config["timezone"] == "Europe/Helsinki"
assert config["automerge"] is False
assert "automergeSchedule" not in config
assert "platformAutomerge" not in config
assert config["rebaseWhen"] == "auto"
assert config["vulnerabilityAlerts"]["enabled"] is True
assert config["dependencyDashboardApproval"] is False
# Upstream controller YAML is vendored, checksummed and image-pinned separately.
assert "kubernetes/infrastructure/snapshot-controller/config/upstream/**" in config["ignorePaths"]

rules = config["packageRules"]
assert all(rule.get("automerge") is not True for rule in rules)
assert all("automergeSchedule" not in rule for rule in rules)
assert rules[-1].get("matchPackageNames") == ["*"]
assert rules[-1].get("automerge") is False  # Override any inherited automerge rules
# Talos/Kubernetes version pins are managed and tested in the private repository.
assert not any('talos/' in name for rule in rules for name in rule.get('matchFileNames', []))
assert any(
    {"siderolabs/talos", "kubernetes/kubernetes"}.issubset(
        set(r.get("matchPackageNames", []))
    ) and r.get("automerge") is False
    for r in rules
)
print("PASS: Renovate creates PRs but cannot autonomously merge them")
PY

# OCI chart discovery must retain immutable artifact selection.
while IFS= read -r path; do
  yq -e 'select(.kind == "OCIRepository") | (.spec.ref.tag | test("^v?[0-9]+[.][0-9]+[.][0-9]+")) and (.spec.ref.digest | test("^sha256:[a-f0-9]{64}$")) and (.spec.ref | has("semver") | not)' "$repo_root/$path" >/dev/null
done <<'EOF'
kubernetes/flux/repositories/bjw-s-app-template.yaml
kubernetes/applications/immich/config/ocirepository.yaml
kubernetes/infrastructure/flux-web-ui/app/ocirepository.yaml
kubernetes/infrastructure/flux-operator/app/ocirepository.yaml
EOF

# The only merge actor is the lightweight nightly Actions job.
yq -o=json '.' "$repo_root/.github/workflows/renovate-nightly-merge.yaml" | jq -e '
  .on.schedule == [{"cron":"7,22,37,52 0-3 * * *","timezone":"Europe/Helsinki"}] and
  .on.pull_request_target.types ==
    ["opened","reopened","synchronize","ready_for_review"] and
  .concurrency["cancel-in-progress"] == false and
  .permissions == {} and
  (.jobs.merge.if | contains("vars.RENOVATE_NIGHTLY_MERGE_ENABLED == \u0027true\u0027")) and
  (.jobs.merge.if | contains("github.event.pull_request.head.repo.full_name == github.repository")) and
  .jobs.merge.permissions == {"checks":"read","contents":"write","pull-requests":"read"} and
  .jobs.merge["timeout-minutes"] == 5 and
  (.jobs.merge.steps | length) == 1 and
  (.jobs.merge.steps[0].run | contains("TZ=Europe/Helsinki date +%H")) and
  (.jobs.merge.steps[0].run | contains("00|01|02|03")) and
  (.jobs.merge.steps[0].run | contains("00|01")) and
  (.jobs.merge.steps[0].run | contains(".user.login == \"renovate[bot]\"")) and
  (.jobs.merge.steps[0].run | contains("siderolabs/talos|kubernetes/kubernetes")) and
  (.jobs.merge.steps[0].run | contains("check-runs?check_name=desired-state&filter=latest")) and
  (.jobs.merge.steps[0].run | contains(".head_sha == $sha")) and
  (.jobs.merge.steps[0].run | contains(".conclusion == \"success\"")) and
  (.jobs.merge.steps[0].run | contains(".app.slug == \"github-actions\"")) and
  (.jobs.merge.steps[0].run | contains("case \"$mergeable_state\" in")) and
  (.jobs.merge.steps[0].run | contains("clean|unstable)")) and
  (.jobs.merge.steps[0].run | contains("Deferring #$number: exact-head desired-state")) and
  (.jobs.merge.steps[0].run | contains("gh api -X PUT")) and
  (.jobs.merge.steps[0].run | contains("-f sha=\"$head_sha\" -f merge_method=squash")) and
  ([.jobs.merge.steps[].uses // empty] | length) == 0
' >/dev/null
echo "PASS: Actions merges only eligible Renovate PRs in the night window"

# Longhorn native V1 engine upgrades are managed by Longhorn, not the PR merger.
yq -o=json '.' "$repo_root/kubernetes/infrastructure/longhorn/app/helmrelease.yaml" | jq -e '
  .spec.values.defaultSettings.concurrentAutomaticEngineUpgradePerNodeLimit == 1
' >/dev/null

# The same read-only offline gate runs on human and Renovate PRs.
yq -o=json '.' "$repo_root/.github/workflows/validate-desired-state.yaml" | jq -e '
  .permissions == {"contents":"read"} and
  .on.pull_request.branches == ["main"] and
  (.on.pull_request | has("paths-ignore") | not) and
  .jobs.validate.name == "desired-state" and
  (.jobs.validate | has("if") | not) and
  ([.jobs.validate.steps[].run // ""] | any(contains("./scripts/validate-complete-desired-state.sh"))) and
  ([.jobs.validate.steps[].run // ""] | any(contains("renovate-config-validator"))) and
  ([.jobs.validate.steps[].with // {} | select(has("persist-credentials"))] | all(."persist-credentials" == false))
' >/dev/null
