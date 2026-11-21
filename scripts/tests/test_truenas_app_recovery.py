"""Offline tests: no real middleware, datasets or containers are accessed."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "truenas_recovery", Path(__file__).resolve().parents[1] / "truenas-app-recovery.py"
)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.state = "STOPPED"
        self.mounted = "yes"
        self.key = "available"
        self.jobs = []
        self.containers = {"id": {"state": "created"}}
        self.commands = []
        self.config = {"garage": ["tank/garage"]}
        self.command_patch = patch.object(recovery, "command", self.native_command)
        self.command_patch.start()
        self.addCleanup(self.command_patch.stop)
        self.syslog_patch = patch.object(recovery.syslog, "syslog")
        self.syslog_patch.start()
        self.addCleanup(self.syslog_patch.stop)

    def native_command(self, *args):
        self.commands.append(args)
        if args[0] == recovery.ZFS:
            return f"encryption\taes-256-gcm\nmounted\t{self.mounted}\nkeystatus\t{self.key}\n"
        self.assertEqual(args[:4], (recovery.MIDCLT, "-t", "15", "call"))
        method = args[4]
        if method == "core.get_jobs":
            # Jobs may contain credentials and application arguments. Require
            # server-side selection before any data reaches the script.
            self.assertEqual(json.loads(args[6]), {"select": ["id", "method"]})
            return json.dumps(self.jobs)
        if method == "app.query":
            self.assertEqual(json.loads(args[5]), [["id", "in", ["garage"]]])
            self.assertEqual(json.loads(args[6]), {"select": ["id", "state"]})
            return json.dumps([{"id": "garage", "state": self.state}])
        if method == "app.container_ids":
            return json.dumps(self.containers)
        self.assertEqual(method, "app.start")
        self.assertEqual(json.loads(args[5]), "garage")
        return "123"

    def run_recovery(self, apply=True):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            recovery.recover(self.config, apply)
        return output.getvalue()

    def starts(self):
        return [args for args in self.commands if "app.start" in args]

    def test_locked_or_unmounted_storage_never_starts(self):
        for mounted, key in (("no", "unavailable"), ("no", "available"),
                             ("yes", "unavailable")):
            with self.subTest(mounted=mounted, key=key):
                self.mounted, self.key = mounted, key
                self.run_recovery()
                self.assertEqual(self.starts(), [])

    def test_start_after_unlock_and_mount(self):
        self.key, self.mounted = "unavailable", "no"
        self.run_recovery()
        self.assertEqual(self.starts(), [])
        self.key, self.mounted = "available", "yes"
        self.run_recovery()
        self.assertEqual(len(self.starts()), 1)

    def test_crashed_and_stopped_are_always_on(self):
        for state in ("CRASHED", "STOPPED"):
            self.state = state
            self.run_recovery()
        self.assertEqual(len(self.starts()), 2)

    def test_healthy_and_stopping_apps_untouched(self):
        for state in ("RUNNING", "STOPPING", "UNKNOWN"):
            self.state = state
            self.run_recovery()
        self.assertEqual(self.starts(), [])

    def test_stuck_created_container_can_recover(self):
        self.state = "DEPLOYING"
        self.run_recovery()
        self.assertEqual(len(self.starts()), 1)

    def test_real_startup_and_empty_inventory_not_recreated(self):
        self.state = "DEPLOYING"
        for states in ([], ["starting"], ["running"], ["created", "starting"]):
            self.containers = {str(i): {"state": value} for i, value in enumerate(states)}
            self.run_recovery()
        self.assertEqual(self.starts(), [])

    def test_active_server_job_survives_client_and_blocks_duplicate(self):
        self.jobs = [{"id": 123, "method": "app.start"}]
        self.run_recovery()
        self.assertEqual(len(self.commands), 1)
        self.assertEqual(self.starts(), [])

    def test_dry_run_never_submits_job(self):
        self.assertIn("WOULD START garage", self.run_recovery(apply=False))
        self.assertEqual(self.starts(), [])

    def test_every_required_dataset_must_be_ready(self):
        self.config["garage"].append("tank/another-dataset")
        native = self.native_command

        def missing_second_mount(*args):
            if args[-1] == "tank/another-dataset":
                return "mounted\tno\nkeystatus\tunavailable\n"
            return native(*args)

        with patch.object(recovery, "command", missing_second_mount):
            self.run_recovery()
        self.assertEqual(self.starts(), [])

    def test_unavailable_api_fails_without_start(self):
        with patch.object(recovery, "command", side_effect=RuntimeError("unavailable")):
            with self.assertRaises(RuntimeError):
                self.run_recovery()
        self.assertEqual(self.starts(), [])

    def test_native_calls_have_deadline_and_hide_command_output(self):
        self.command_patch.stop()
        with patch.object(recovery.subprocess, "run") as run:
            run.side_effect = subprocess.TimeoutExpired("midclt", 20)
            with self.assertRaises(RuntimeError):
                recovery.command("midclt", "-t", "15", "call", "app.query")
            self.assertEqual(run.call_args.kwargs["timeout"], 20)

    def test_unencrypted_mount_requires_explicit_encryption_off(self):
        with patch.object(recovery, "command", return_value=(
                "encryption\toff\nmounted\tyes\nkeystatus\t-\n")):
            self.assertTrue(recovery.dataset_ready("scratch/ix-apps"))
        with patch.object(recovery, "command", return_value=(
                "encryption\taes-256-gcm\nmounted\tyes\nkeystatus\t-\n")):
            self.assertFalse(recovery.dataset_ready("tank/garage"))

    def test_overlapping_invocation_does_not_query_or_start(self):
        with tempfile.TemporaryDirectory() as directory:
            config_path = Path(directory) / "config.json"
            config_path.write_text(json.dumps(self.config))
            lock_path = str(Path(directory) / "lock")
            with open(lock_path, "a") as lock:
                recovery.fcntl.flock(lock, recovery.fcntl.LOCK_EX)
                with patch.object(recovery, "LOCK_PATH", lock_path), patch.object(
                        recovery.sys, "argv", ["recovery", str(config_path), "--apply"]):
                    self.assertEqual(recovery.main(), 0)
            self.assertEqual(self.commands, [])

    def test_config_requires_explicit_dependencies(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "apps.json"
            for value in ({}, {"garage": []}, {"garage": ["-invalid"]}):
                path.write_text(json.dumps(value))
                with self.assertRaises(ValueError):
                    recovery.load_config(path)


if __name__ == "__main__":
    unittest.main()
