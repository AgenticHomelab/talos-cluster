#!/usr/bin/env python3
"""Emit repeatable alerts for untriaged Renovate security pull requests."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any

from renovate_pr_context import GitHubAPI, collect, github_token, load_state


def select_alerts(context: dict[str, Any]) -> list[dict[str, Any]]:
    selected = [
        item
        for item in context.get("pull_requests", [])
        if isinstance(item, dict) and item.get("security_hint")
    ]
    selected.sort(key=lambda item: int(item["number"]))
    return selected


def build_alert(items: list[dict[str, Any]]) -> str:
    lines = ["🚨 SECURITY UPDATE NEEDS TRIAGE", ""]
    for item in items:
        version = ""
        if item.get("old_version") and item.get("new_version"):
            version = f" ({item['old_version']} → {item['new_version']})"
        package = item.get("package") or item.get("title") or "unknown package"
        lines.append(f"- #{item['number']} {package}{version}")
        lines.append(f"  {item['url']}")
    lines.extend(
        [
            "",
            "This alert repeats until triaged and the exact head SHA is marked analyzed. Request operator security review; this alert is not a merge authorization.",
        ]
    )
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="AgenticHomelab/talos-cluster")
    parser.add_argument(
        "--state-file",
        type=Path,
        default=Path("/opt/data/cron/state/renovate-pr-heads.json"),
    )
    args = parser.parse_args(argv)

    try:
        state = load_state(args.state_file)
        context = collect(args.repo, state, GitHubAPI(github_token()))
        alerts = select_alerts(context)
        if alerts:
            print(build_alert(alerts))
        return 0
    except Exception as error:
        print(f"renovate security watch failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
