#!/usr/bin/env python3
import json
import stat
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "automation"))

from renovate_pr_context import GitHubAPI, build_context, mark_analyzed  # noqa: E402


def pull(number=10, *, author="renovate[bot]", base="main", sha="a" * 40, body=""):
    return {
        "number": number,
        "html_url": f"https://github.com/AgenticHomelab/talos-cluster/pull/{number}",
        "title": "fix(container): update image example (1.0.0 ➔ 1.0.1)",
        "user": {"login": author, "type": "Bot"},
        "base": {"ref": base},
        "head": {
            "sha": sha,
            "ref": f"renovate/example-{number}",
            "repo": {"full_name": "AgenticHomelab/talos-cluster"},
        },
        "draft": False,
        "body": body,
        "labels": [{"name": "dependencies"}],

    }


class BuildContextTests(unittest.TestCase):
    def test_rejects_non_bot_or_untrusted_head_repository(self):
        non_bot = pull(12)
        non_bot["user"]["type"] = "User"
        fork = pull(13)
        fork["head"]["repo"]["full_name"] = "mallory/talos-homelab"
        wrong_ref = pull(14)
        wrong_ref["head"]["ref"] = "feature/not-renovate"

        result = build_context(
            "AgenticHomelab/talos-cluster",
            [non_bot, fork, wrong_ref],
            {"version": 1, "analyzed": {}},
        )

        self.assertEqual([], result["pull_requests"])


    def test_sanitizes_release_evidence_without_debug_blob(self):
        body = """### Release Notes
https://github.com/example/project/releases/tag/v1.0.1
https://github.com/example/project/compare/v1.0.0...v1.0.1
<!--renovate-debug:SECRET-BLOB-->
"""

        result = build_context(
            "AgenticHomelab/talos-cluster", [pull(body=body)], {"version": 1, "analyzed": {}}
        )

        item = result["pull_requests"][0]
        self.assertEqual(2, len(item["evidence_links"]))
        serialized = json.dumps(result)
        self.assertNotIn("SECRET-BLOB", serialized)
        self.assertNotIn("renovate-debug", serialized)

    def test_sanitizes_credentials_and_queries_from_evidence_urls(self):
        body = (
            "https://user:secret@example.com/releases/v1?token=sensitive#fragment\n"
            "https://example.com/compare/v0...v1?signature=sensitive"
        )

        item = build_context(
            "AgenticHomelab/talos-cluster", [pull(body=body)], {"version": 1, "analyzed": {}}
        )["pull_requests"][0]

        self.assertEqual(
            [
                "https://example.com/releases/v1",
                "https://example.com/compare/v0...v1",
            ],
            item["evidence_links"],
        )
        self.assertNotIn("sensitive", json.dumps(item))


class GitHubAPITests(unittest.TestCase):
    def test_paginates_open_pull_requests(self):
        class StubAPI(GitHubAPI):
            def __init__(self):
                pass

            def get(self, path):
                if path.endswith("page=1"):
                    return [pull(number=i) for i in range(1, 101)]
                if path.endswith("page=2"):
                    return [pull(number=101)]
                raise AssertionError(path)

        result = StubAPI().list_open_pulls("AgenticHomelab/talos-cluster")

        self.assertEqual(101, len(result))

    def test_rejects_snapshot_when_head_changes_during_collection(self):
        class StubAPI(GitHubAPI):
            def __init__(self):
                self.detail_calls = 0

            def get(self, path):
                if path.endswith("/pulls/10"):
                    self.detail_calls += 1
                    return pull(sha=("a" if self.detail_calls == 1 else "b") * 40)
                if "/files?" in path:
                    return []
                if "/check-runs?" in path:
                    return {"total_count": 0, "check_runs": []}
                if "/status?" in path:
                    return {"state": "pending", "total_count": 0, "statuses": []}
                if "/actions/runs?" in path:
                    return {"total_count": 0, "workflow_runs": []}
                raise AssertionError(path)

        with self.assertRaisesRegex(RuntimeError, "head SHA changed"):
            StubAPI().enrich_pull("AgenticHomelab/talos-cluster", {"number": 10})


class StateTests(unittest.TestCase):
    def test_mark_analyzed_preserves_other_state_and_uses_private_mode(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            path.write_text(
                json.dumps(
                    {
                        "version": 1,
                        "analyzed": {},
                        "security_alerted": {"7": "c" * 40},
                    }
                )
            )

            mark_analyzed(path, 10, "a" * 40)

            state = json.loads(path.read_text())
            self.assertEqual("a" * 40, state["analyzed"]["10"])
            self.assertEqual("c" * 40, state["security_alerted"]["7"])
            self.assertEqual(0o600, stat.S_IMODE(path.stat().st_mode))

    def test_mark_analyzed_rejects_invalid_sha(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaises(ValueError):
                mark_analyzed(Path(tmp) / "state.json", 10, "not-a-sha")


if __name__ == "__main__":
    unittest.main()
