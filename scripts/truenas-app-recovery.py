#!/usr/bin/env python3
"""Recover explicitly always-on TrueNAS 25.10 Apps after dataset unlock."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import syslog


LOCK_PATH = "/run/truenas-app-recovery.lock"
MIDCLT = "/usr/bin/midclt"
ZFS = "/usr/sbin/zfs"


def command(*args):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise RuntimeError(f"{args[0]} unavailable or timed out") from exc
    if result.returncode:
        # Middleware errors can include application configuration. Do not log it.
        raise RuntimeError(f"{args[0]} failed (exit {result.returncode})")
    return result.stdout


def call(method, *args):
    try:
        return json.loads(command(MIDCLT, "-t", "15", "call", method,
                                  *(json.dumps(arg) for arg in args)))
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"invalid response from {method}") from exc


def load_config(path):
    config = json.loads(Path(path).read_text())
    if not isinstance(config, dict) or not config:
        raise ValueError("configuration must map app names to required datasets")
    for app, datasets in config.items():
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", app):
            raise ValueError("invalid app name")
        if not isinstance(datasets, list) or not datasets:
            raise ValueError(f"{app}: at least one required dataset is mandatory")
        if any(not isinstance(ds, str) or not re.fullmatch(
                r"[A-Za-z0-9][A-Za-z0-9_./:-]*", ds) for ds in datasets):
            raise ValueError(f"{app}: invalid dataset name")
    return config


def dataset_ready(dataset):
    properties = dict(line.split("\t") for line in command(
        ZFS, "get", "-H", "-o", "property,value", "encryption,mounted,keystatus", dataset
    ).splitlines())
    key_ready = properties.get("keystatus") == "available"
    if properties.get("encryption") == "off":
        # Native ZFS CLI reports '-' on this host for unencrypted datasets.
        key_ready = properties.get("keystatus") in {"-", "none"}
    return properties.get("mounted") == "yes" and key_ready


def recover(config, apply=False):
    jobs = call("core.get_jobs", [
        ["state", "in", ["WAITING", "RUNNING"]], ["method", "^", "app."]
    ], {"select": ["id", "method"]})
    if not isinstance(jobs, list):
        raise RuntimeError("invalid app job inventory")
    if jobs:
        if not apply:
            print("SKIP: an Apps operation is already active")
        return

    apps = call("app.query", [["id", "in", list(config)]],
                {"select": ["id", "state"]})
    if not isinstance(apps, list):
        raise RuntimeError("invalid app inventory")
    by_name = {app["id"]: app["state"] for app in apps}
    if set(by_name) != set(config):
        raise RuntimeError("configured app is missing; check the allowlist")

    for app, datasets in config.items():
        state = by_name[app]
        eligible = state in {"STOPPED", "CRASHED"}
        if state == "DEPLOYING":
            # A mount failure can leave Docker containers CREATED forever.
            # STARTING means a process is alive; never interrupt its healthcheck.
            containers = call("app.container_ids", app, {"alive_only": False})
            if not isinstance(containers, dict):
                raise RuntimeError("invalid container inventory")
            states = [item["state"] for item in containers.values()]
            eligible = bool(states) and all(item == "created" for item in states)
        if not eligible:
            if not apply:
                print(f"SKIP {app}: state {state}")
            continue
        if not all(dataset_ready(dataset) for dataset in datasets):
            if not apply:
                print(f"WAIT {app}: a required dataset is locked or unmounted")
            continue
        if not apply:
            print(f"WOULD START {app}: state {state}, datasets ready")
            continue
        # Do not wait on a long-running server job. Next cron tick sees it above.
        job_id = call("app.start", app)
        if not isinstance(job_id, int) or isinstance(job_id, bool):
            raise RuntimeError(f"{app}: invalid start job response")
        message = f"Requested start of {app} (job {job_id})"
        print(message, flush=True)
        syslog.syslog(syslog.LOG_NOTICE, message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("config", help="JSON app-to-datasets allowlist")
    parser.add_argument("--apply", action="store_true", help="submit start jobs")
    args = parser.parse_args()
    syslog.openlog("truenas-app-recovery")
    try:
        config = load_config(args.config)
        # /run is root-owned and available before encrypted datasets unlock.
        with os.fdopen(os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o600), "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 0
            recover(config, args.apply)
    except (OSError, ValueError, KeyError, TypeError, RuntimeError) as exc:
        # Do not print config contents or native command output on an error.
        message = f"Recovery check failed: {type(exc).__name__}; check native Apps/storage status"
        print(message, file=sys.stderr)
        syslog.syslog(syslog.LOG_ERR, message)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
