#!/usr/bin/env python3
"""Collect changed Renovate pull-request context without exposing credentials."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

RENOVATE_LOGIN = "renovate[bot]"
REQUIRED_CHECKS = ("desired-state",)
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
URL_RE = re.compile(r"https://[^\s<>\])}]+")
VERSION_RE = re.compile(r"\(([^()\s]+)\s+(?:➔|->)\s+([^()\s]+)\)\s*$")
PACKAGE_RE = re.compile(
    r"update (?:image|chart|dependency|package|action|release|tool)\s+(.+?)\s+\(",
    re.IGNORECASE,
)
TRUNCATED_MARKERS = ("body was truncated", "platform limits")
SECURITY_TERMS = ("security", "vulnerability", "vulnerability alert", "cve-", "ghsa-")


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"version": 1, "analyzed": {}}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("state root must be an object")
    data.setdefault("version", 1)
    data.setdefault("analyzed", {})
    if not isinstance(data["analyzed"], dict):
        raise ValueError("state analyzed map must be an object")
    return data


def save_state(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(data, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass
        raise


@contextmanager
def locked_state(path: Path) -> Iterator[dict[str, Any]]:
    path.parent.mkdir(parents=True, exist_ok=True)
    lock_path = path.with_name(f"{path.name}.lock")
    with lock_path.open("a+", encoding="utf-8") as lock:
        os.chmod(lock_path, 0o600)
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        yield load_state(path)


def mark_analyzed(path: Path, number: int, head_sha: str) -> None:
    if number <= 0:
        raise ValueError("pull request number must be positive")
    if not SHA_RE.fullmatch(head_sha):
        raise ValueError(
            "head SHA must contain exactly 40 lowercase hexadecimal characters"
        )
    with locked_state(path) as state:
        state["analyzed"][str(number)] = head_sha
        save_state(path, state)


def _mapping(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _labels(pr: dict[str, Any]) -> list[str]:
    return sorted(
        str(item.get("name", ""))
        for item in pr.get("labels", [])
        if isinstance(item, dict) and item.get("name")
    )


def _sanitize_url(candidate: str) -> str | None:
    try:
        parsed = urllib.parse.urlsplit(candidate)
        if parsed.scheme != "https" or not parsed.hostname:
            return None
        host = parsed.hostname.lower()
        if parsed.port:
            host = f"{host}:{parsed.port}"
        return urllib.parse.urlunsplit(("https", host, parsed.path, "", ""))
    except (ValueError, UnicodeError):
        return None


def _release_links(body: str) -> list[str]:
    links: list[str] = []
    for raw in URL_RE.findall(body):
        candidate = _sanitize_url(raw.rstrip(".,;`"))
        if not candidate:
            continue
        lower = candidate.lower()
        if any(
            part in lower
            for part in (
                "/releases/",
                "/compare/",
                "changelog",
                "migration",
                "upgrade",
                "security/advisories",
            )
        ):
            if candidate not in links:
                links.append(candidate)
        if len(links) >= 30:
            break
    return links


def _package_and_versions(title: str) -> tuple[str | None, str | None, str | None]:
    package_match = PACKAGE_RE.search(title)
    version_match = VERSION_RE.search(title)
    package = package_match.group(1).strip() if package_match else None
    old_version = version_match.group(1) if version_match else None
    new_version = version_match.group(2) if version_match else None
    return package, old_version, new_version


def _is_renovate_to_main(repo: str, pr: dict[str, Any]) -> bool:
    user = _mapping(pr.get("user"))
    base = _mapping(pr.get("base"))
    head = _mapping(pr.get("head"))
    head_repo = _mapping(head.get("repo"))
    return (
        user.get("login") == RENOVATE_LOGIN
        and user.get("type") == "Bot"
        and base.get("ref") == "main"
        and head_repo.get("full_name") == repo
        and str(head.get("ref", "")).startswith("renovate/")
        and SHA_RE.fullmatch(str(head.get("sha", ""))) is not None
    )


def _check_gate(pr: dict[str, Any]) -> dict[str, Any]:
    actions_by_name = {
        str(job.get("name", "")): job
        for job in pr.get("actions_jobs", [])
        if isinstance(job, dict)
    }
    collection_errors = ["actions"] if pr.get("actions_error") else []
    missing: list[str] = []
    unsuccessful: list[str] = []
    for name in REQUIRED_CHECKS:
        action_job = actions_by_name.get(name)
        if action_job is None:
            missing.append(name)
        elif not (
            action_job.get("workflow_status") == "completed"
            and action_job.get("workflow_conclusion") == "success"
            and action_job.get("status") == "completed"
            and action_job.get("conclusion") == "success"
        ):
            unsuccessful.append(name)
    return {
        "required_checks": list(REQUIRED_CHECKS),
        "required_checks_missing": missing,
        "required_checks_unsuccessful": unsuccessful,
        "required_checks_collection_errors": collection_errors,
        "checks_complete": not collection_errors and not missing and not unsuccessful,
    }


def _compact_pr(pr: dict[str, Any], previous_sha: str | None) -> dict[str, Any]:
    title = str(pr.get("title", ""))
    body = str(pr.get("body") or "")
    user = _mapping(pr.get("user"))
    base = _mapping(pr.get("base"))
    head = _mapping(pr.get("head"))
    head_repo = _mapping(head.get("repo"))
    labels = _labels(pr)
    package, old_version, new_version = _package_and_versions(title)
    security_text = " ".join([title, body, *labels]).lower()
    checks = [
        {
            "name": str(check.get("name", "")),
            "status": str(check.get("status", "")),
            "conclusion": check.get("conclusion"),
        }
        for check in pr.get("check_runs", [])
        if isinstance(check, dict)
    ]
    statuses = [
        {
            "context": str(status.get("context", "")),
            "state": str(status.get("state", "")),
        }
        for status in pr.get("statuses", [])
        if isinstance(status, dict)
    ]
    actions_jobs = [
        {
            "workflow_name": str(job.get("workflow_name", "")),
            "workflow_run_id": int(job.get("workflow_run_id", 0)),
            "workflow_run_attempt": int(job.get("workflow_run_attempt", 0)),
            "workflow_status": str(job.get("workflow_status", "")),
            "workflow_conclusion": job.get("workflow_conclusion"),
            "job_id": int(job.get("job_id", 0)),
            "job_run_attempt": int(job.get("job_run_attempt", 0)),
            "name": str(job.get("name", "")),
            "status": str(job.get("status", "")),
            "conclusion": job.get("conclusion"),
        }
        for job in pr.get("actions_jobs", [])
        if isinstance(job, dict)
    ]
    files = [
        {
            "path": str(item.get("filename", "")),
            "additions": int(item.get("additions", 0)),
            "deletions": int(item.get("deletions", 0)),
        }
        for item in pr.get("files", [])
        if isinstance(item, dict)
    ]
    result = {
        "number": int(pr["number"]),
        "url": str(pr.get("html_url", "")),
        "title": title,
        "author": str(user.get("login", "")),
        "author_type": str(user.get("type", "")),
        "base": str(base.get("ref", "")),
        "head_repo": str(head_repo.get("full_name", "")),
        "head_ref": str(head.get("ref", "")),
        "draft": bool(pr.get("draft", False)),
        "head_sha": str(head.get("sha", "")),
        "analysis_required": True,
        "previous_head_sha": previous_sha,
        "mergeable": pr.get("mergeable"),
        "mergeable_state": pr.get("mergeable_state"),
        "labels": labels,
        "package": package,
        "old_version": old_version,
        "new_version": new_version,
        "body_truncated": any(marker in body.lower() for marker in TRUNCATED_MARKERS),
        "security_hint": any(term in security_text for term in SECURITY_TERMS),
        "evidence_links": _release_links(body),
        "files": files,
        "checks": checks,
        "check_collection_error": pr.get("checks_error"),
        "combined_status_state": pr.get("combined_status_state"),
        "statuses": statuses,
        "status_collection_error": pr.get("status_error"),
        "actions_jobs": actions_jobs,
        "actions_collection_error": pr.get("actions_error"),
    }
    result.update(_check_gate(pr))
    return result


def build_context(
    repo: str, pulls: list[dict[str, Any]], state: dict[str, Any]
) -> dict[str, Any]:
    analyzed = state.get("analyzed", {})
    selected: list[dict[str, Any]] = []
    for pr in pulls:
        if not _is_renovate_to_main(repo, pr):
            continue
        number = str(pr.get("number", ""))
        head_sha = str(_mapping(pr.get("head")).get("sha", ""))
        previous_sha = analyzed.get(number)
        if previous_sha == head_sha:
            continue
        selected.append(_compact_pr(pr, previous_sha))
    selected.sort(key=lambda item: item["number"])
    return {
        "version": 3,
        "repository": repo,
        "count": len(selected),
        "pull_requests": selected,
    }


def _git_credential_token() -> str | None:
    request = b"protocol=https\nhost=github.com\n\n"
    result = subprocess.run(
        ["git", "credential", "fill"],
        input=request,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=10,
    )
    if result.returncode != 0:
        return None
    fields = dict(
        line.split("=", 1)
        for line in result.stdout.decode("utf-8", errors="replace").splitlines()
        if "=" in line
    )
    return fields.get("password")


def github_token() -> str:
    token = (
        os.environ.get("GH_TOKEN")
        or os.environ.get("GITHUB_TOKEN")
        or _git_credential_token()
    )
    if not token:
        raise RuntimeError("GitHub credential unavailable")
    return token


class GitHubAPI:
    def __init__(self, token: str, api_url: str = "https://api.github.com") -> None:
        self._token = token
        self._api_url = api_url.rstrip("/")

    def get(self, path: str) -> Any:
        request = urllib.request.Request(
            f"{self._api_url}{path}",
            headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {self._token}",
                "User-Agent": "talos-homelab-renovate-review/2",
                "X-GitHub-Api-Version": "2022-11-28",
            },
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            message = error.read(500).decode("utf-8", errors="replace")
            raise RuntimeError(
                f"GitHub API request failed with HTTP {error.code}: {message}"
            ) from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"GitHub API request failed: {error.reason}") from error

    def _paginated_list(self, path: str) -> list[dict[str, Any]]:
        separator = "&" if "?" in path else "?"
        items: list[dict[str, Any]] = []
        for page in range(1, 101):
            response = self.get(f"{path}{separator}per_page=100&page={page}")
            if not isinstance(response, list) or any(
                not isinstance(item, dict) for item in response
            ):
                raise RuntimeError(
                    "GitHub paginated response was not a list of objects"
                )
            items.extend(response)
            if len(response) < 100:
                return items
        raise RuntimeError("GitHub pagination exceeded the 10,000 item safety limit")

    def list_open_pulls(self, repo: str) -> list[dict[str, Any]]:
        return self._paginated_list(f"/repos/{repo}/pulls?state=open")

    def _check_runs(self, repo: str, sha: str) -> list[dict[str, Any]]:
        checks: list[dict[str, Any]] = []
        total_count: int | None = None
        for page in range(1, 101):
            response = self.get(
                f"/repos/{repo}/commits/{sha}/check-runs?per_page=100&page={page}"
            )
            if not isinstance(response, dict) or not isinstance(
                response.get("check_runs"), list
            ):
                raise RuntimeError("GitHub check-runs response was malformed")
            if total_count is None:
                total_count = int(response.get("total_count", -1))
                if total_count < 0:
                    raise RuntimeError("GitHub check-runs total_count was missing")
            page_checks = response["check_runs"]
            if any(not isinstance(item, dict) for item in page_checks):
                raise RuntimeError("GitHub check-runs response contained a non-object")
            for item in page_checks:
                if (
                    not isinstance(item.get("name"), str)
                    or not item["name"]
                    or not isinstance(item.get("status"), str)
                    or not item["status"]
                    or (
                        item.get("conclusion") is not None
                        and not isinstance(item.get("conclusion"), str)
                    )
                ):
                    raise RuntimeError("GitHub check-run object was malformed")
            checks.extend(page_checks)
            if len(checks) >= total_count:
                if len(checks) != total_count:
                    raise RuntimeError(
                        "GitHub check-runs count did not match total_count"
                    )
                return checks
            if len(page_checks) < 100:
                raise RuntimeError(
                    "GitHub check-runs pagination ended before total_count"
                )
        raise RuntimeError("GitHub check-runs pagination exceeded safety limit")

    def _statuses(self, repo: str, sha: str) -> tuple[str | None, list[dict[str, Any]]]:
        statuses: list[dict[str, Any]] = []
        combined_state: str | None = None
        total_count: int | None = None
        for page in range(1, 101):
            response = self.get(
                f"/repos/{repo}/commits/{sha}/status?per_page=100&page={page}"
            )
            if not isinstance(response, dict) or not isinstance(
                response.get("statuses"), list
            ):
                raise RuntimeError("GitHub combined-status response was malformed")
            if combined_state is None:
                combined_state = str(response.get("state", "")) or None
            if total_count is None:
                total_count = int(response.get("total_count", -1))
                if total_count < 0:
                    raise RuntimeError("GitHub combined-status total_count was missing")
            page_statuses = response["statuses"]
            if any(not isinstance(item, dict) for item in page_statuses):
                raise RuntimeError(
                    "GitHub combined-status response contained a non-object"
                )
            for item in page_statuses:
                if (
                    not isinstance(item.get("context"), str)
                    or not item["context"]
                    or item.get("state")
                    not in {"error", "failure", "pending", "success"}
                ):
                    raise RuntimeError("GitHub combined-status object was malformed")
            statuses.extend(page_statuses)
            if len(statuses) >= total_count:
                if len(statuses) != total_count:
                    raise RuntimeError(
                        "GitHub combined-status count did not match total_count"
                    )
                return combined_state, statuses
            if len(page_statuses) < 100:
                raise RuntimeError(
                    "GitHub combined-status pagination ended before total_count"
                )
        raise RuntimeError("GitHub combined-status pagination exceeded safety limit")

    def _paginated_object_items(
        self, path: str, field: str, label: str
    ) -> list[dict[str, Any]]:
        separator = "&" if "?" in path else "?"
        items: list[dict[str, Any]] = []
        total_count: int | None = None
        for page in range(1, 101):
            response = self.get(f"{path}{separator}per_page=100&page={page}")
            if not isinstance(response, dict) or not isinstance(
                response.get(field), list
            ):
                raise RuntimeError(f"GitHub {label} response was malformed")
            if total_count is None:
                total_count = int(response.get("total_count", -1))
                if total_count < 0:
                    raise RuntimeError(f"GitHub {label} total_count was missing")
            page_items = response[field]
            if any(not isinstance(item, dict) for item in page_items):
                raise RuntimeError(f"GitHub {label} response contained a non-object")
            items.extend(page_items)
            if len(items) >= total_count:
                if len(items) != total_count:
                    raise RuntimeError(
                        f"GitHub {label} count did not match total_count"
                    )
                return items
            if len(page_items) < 100:
                raise RuntimeError(
                    f"GitHub {label} pagination ended before total_count"
                )
        raise RuntimeError(f"GitHub {label} pagination exceeded safety limit")

    def _actions_jobs_snapshot(self, repo: str, sha: str) -> list[dict[str, Any]]:
        runs = self._paginated_object_items(
            f"/repos/{repo}/actions/runs?head_sha={sha}&event=pull_request",
            "workflow_runs",
            "Actions workflow-runs",
        )
        for run in runs:
            if (
                not isinstance(run.get("id"), int)
                or run["id"] <= 0
                or not isinstance(run.get("run_attempt"), int)
                or run["run_attempt"] <= 0
                or not isinstance(run.get("name"), str)
                or not run["name"]
                or run.get("event") != "pull_request"
                or run.get("head_sha") != sha
                or not isinstance(run.get("status"), str)
                or not run["status"]
                or (
                    run.get("conclusion") is not None
                    and not isinstance(run.get("conclusion"), str)
                )
            ):
                raise RuntimeError("GitHub Actions workflow-run object was malformed")

        expected_runs = [run for run in runs if run["name"] == "Validate desired state"]
        if not expected_runs:
            return []
        latest_run = max(expected_runs, key=lambda run: run["id"])
        run_id = latest_run["id"]
        run_attempt = latest_run["run_attempt"]
        jobs = self._paginated_object_items(
            f"/repos/{repo}/actions/runs/{run_id}/attempts/{run_attempt}/jobs?filter=all",
            "jobs",
            "workflow jobs",
        )
        required_jobs: list[dict[str, Any]] = []
        for job in jobs:
            if (
                not isinstance(job.get("id"), int)
                or job["id"] <= 0
                or job.get("run_id") != run_id
                or job.get("run_attempt") != run_attempt
                or job.get("head_sha") != sha
                or not isinstance(job.get("name"), str)
                or not job["name"]
                or not isinstance(job.get("status"), str)
                or not job["status"]
                or (
                    job.get("conclusion") is not None
                    and not isinstance(job.get("conclusion"), str)
                )
            ):
                raise RuntimeError("GitHub Actions job object was malformed")
            if job["name"] in REQUIRED_CHECKS:
                required_jobs.append(
                    {
                        "workflow_name": latest_run["name"],
                        "workflow_run_id": run_id,
                        "workflow_run_attempt": latest_run["run_attempt"],
                        "workflow_status": latest_run["status"],
                        "workflow_conclusion": latest_run.get("conclusion"),
                        "job_id": job["id"],
                        "job_run_attempt": job["run_attempt"],
                        "name": job["name"],
                        "status": job["status"],
                        "conclusion": job.get("conclusion"),
                    }
                )
        names = [job["name"] for job in required_jobs]
        if len(names) != len(set(names)):
            raise RuntimeError("GitHub Actions returned duplicate required job names")
        return required_jobs

    def _actions_jobs(self, repo: str, sha: str) -> list[dict[str, Any]]:
        first = self._actions_jobs_snapshot(repo, sha)
        second = self._actions_jobs_snapshot(repo, sha)
        if first != second:
            raise RuntimeError("GitHub Actions evidence changed during collection")
        return second

    def enrich_pull(self, repo: str, summary: dict[str, Any]) -> dict[str, Any]:
        number = int(summary["number"])
        detail = self.get(f"/repos/{repo}/pulls/{number}")
        if not isinstance(detail, dict):
            raise RuntimeError("GitHub pull detail response was malformed")
        sha = str(_mapping(detail.get("head")).get("sha", ""))
        if not SHA_RE.fullmatch(sha):
            raise RuntimeError("GitHub pull detail returned an invalid head SHA")
        summary_sha = str(_mapping(summary.get("head")).get("sha", ""))
        if summary_sha and summary_sha != sha:
            raise RuntimeError(
                "pull request head SHA changed before snapshot collection"
            )

        files = self._paginated_list(f"/repos/{repo}/pulls/{number}/files")
        for item in files:
            if (
                not isinstance(item.get("filename"), str)
                or not item["filename"]
                or not isinstance(item.get("additions"), int)
                or item["additions"] < 0
                or not isinstance(item.get("deletions"), int)
                or item["deletions"] < 0
            ):
                raise RuntimeError("GitHub file object was malformed")

        checks: list[dict[str, Any]] = []
        checks_error: str | None = None
        try:
            checks = self._check_runs(repo, sha)
        except RuntimeError as error:
            checks_error = str(error)[:500]

        statuses: list[dict[str, Any]] = []
        combined_state: str | None = None
        status_error: str | None = None
        try:
            combined_state, statuses = self._statuses(repo, sha)
        except RuntimeError as error:
            status_error = str(error)[:500]

        actions_jobs: list[dict[str, Any]] = []
        actions_error: str | None = None
        try:
            actions_jobs = self._actions_jobs(repo, sha)
        except RuntimeError as error:
            actions_error = str(error)[:500]

        final_detail = self.get(f"/repos/{repo}/pulls/{number}")
        if not isinstance(final_detail, dict):
            raise RuntimeError("GitHub final pull detail response was malformed")
        final_sha = str(_mapping(final_detail.get("head")).get("sha", ""))
        if final_sha != sha:
            raise RuntimeError(
                "pull request head SHA changed during snapshot collection"
            )

        detail["files"] = files
        detail["check_runs"] = checks
        detail["checks_error"] = checks_error
        detail["combined_status_state"] = combined_state
        detail["statuses"] = statuses
        detail["status_error"] = status_error
        detail["actions_jobs"] = actions_jobs
        detail["actions_error"] = actions_error
        return detail


def collect(repo: str, state: dict[str, Any], api: GitHubAPI) -> dict[str, Any]:
    summaries = api.list_open_pulls(repo)
    analyzed = state.get("analyzed", {})
    changed = [
        item
        for item in summaries
        if _is_renovate_to_main(repo, item)
        and analyzed.get(str(item.get("number", "")))
        != str(_mapping(item.get("head")).get("sha", ""))
    ]
    enriched = [api.enrich_pull(repo, item) for item in changed]
    return build_context(repo, enriched, state)


def parse_mark(value: str) -> tuple[int, str]:
    try:
        number_text, sha = value.split("=", 1)
        return int(number_text), sha
    except (ValueError, TypeError) as error:
        raise argparse.ArgumentTypeError(
            "mark must use PR=40-char-lowercase-SHA"
        ) from error


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="AgenticHomelab/talos-cluster")
    parser.add_argument(
        "--state-file",
        type=Path,
        default=Path("/opt/data/cron/state/renovate-pr-heads.json"),
    )
    parser.add_argument(
        "--mark", type=parse_mark, help="mark analysis complete as PR=HEAD_SHA"
    )
    parser.add_argument("--pretty", action="store_true")
    args = parser.parse_args(argv)

    try:
        if args.mark:
            mark_analyzed(args.state_file, *args.mark)
            return 0
        state = load_state(args.state_file)
        result = collect(args.repo, state, GitHubAPI(github_token()))
        print(
            json.dumps(
                result,
                ensure_ascii=False,
                indent=2 if args.pretty else None,
                separators=None if args.pretty else (",", ":"),
            )
        )
        return 0
    except Exception as error:
        print(f"renovate context collection failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
