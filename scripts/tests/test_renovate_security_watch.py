#!/usr/bin/env python3
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "scripts" / "automation"))

from renovate_pr_context import build_context  # noqa: E402
from renovate_security_watch import build_alert, select_alerts  # noqa: E402


def item(number=10, sha="a" * 40, *, security=True):
    return {
        "number": number,
        "url": f"https://github.com/AgenticHomelab/talos-cluster/pull/{number}",
        "title": "fix(container): update security-sensitive image (1.0.0 ➔ 1.0.1)",
        "head_sha": sha,
        "security_hint": security,
        "labels": ["security"] if security else ["dependencies"],
        "package": "example/image",
        "old_version": "1.0.0",
        "new_version": "1.0.1",
    }


def renovate_pull(number=10, sha="a" * 40):
    return {
        "number": number,
        "html_url": f"https://github.com/AgenticHomelab/talos-cluster/pull/{number}",
        "title": "fix(container): update security-sensitive image (1.0.0 ➔ 1.0.1)",
        "user": {"login": "renovate[bot]", "type": "Bot"},
        "base": {"ref": "main"},
        "head": {
            "sha": sha,
            "ref": f"renovate/example-{number}",
            "repo": {"full_name": "AgenticHomelab/talos-cluster"},
        },
        "draft": False,
        "body": "security update",
        "labels": [{"name": "security"}],
        "mergeable": True,
        "mergeable_state": "clean",
        "files": [],
        "check_runs": [],
    }


class SecuritySelectionTests(unittest.TestCase):
    def test_selects_only_security_hints(self):
        context = {"pull_requests": [item(10), item(11, "b" * 40, security=False)]}

        selected = select_alerts(context)

        self.assertEqual([10], [entry["number"] for entry in selected])


    def test_rebased_security_head_alerts_until_that_exact_head_is_marked(self):
        rebased = renovate_pull(10, "b" * 40)

        changed = build_context(
            "AgenticHomelab/talos-cluster", [rebased], {"version": 1, "analyzed": {"10": "a" * 40}}
        )
        exact = build_context(
            "AgenticHomelab/talos-cluster", [rebased], {"version": 1, "analyzed": {"10": "b" * 40}}
        )

        self.assertEqual([10], [entry["number"] for entry in select_alerts(changed)])
        self.assertEqual([], select_alerts(exact))


class SecurityOutputTests(unittest.TestCase):
    def test_alert_contains_actionable_metadata(self):
        message = build_alert([item()])

        self.assertIn("#10", message)
        self.assertIn("1.0.0 → 1.0.1", message)
        self.assertIn("https://github.com/AgenticHomelab/talos-cluster/pull/10", message)
        self.assertNotIn("token", message.lower())


if __name__ == "__main__":
    unittest.main()
