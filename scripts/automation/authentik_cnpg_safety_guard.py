#!/usr/bin/env python3
"""Fail-closed read-only safety preflight for the Authentik CNPG cluster."""
from __future__ import annotations

import argparse
import json
import math
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

DEFAULT_NAMESPACE = "authentik"
DEFAULT_CLUSTER = "authentik-postgres"
METRICS_PORT = 9187
MAX_WAL_FRACTION = 0.50
MAX_INACTIVE_SLOT_LAG_FRACTION = 0.10
HEALTHY_PHASE = "Cluster in healthy state"
HA_SLOT_PREFIX = "_cnpg_"

SAMPLE_RE = re.compile(
    r"^([A-Za-z_:][A-Za-z0-9_:]*)(?:\{(.*)\})?\s+([^\s]+)(?:\s+\d+)?$"
)
LABEL_RE = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"\\])*)"')
QUANTITY_RE = re.compile(r"^(\d+(?:\.\d+)?)([KMGTPE]i|[kMGTPE]|m)?$")

BINARY_UNITS = {
    "Ki": 1024,
    "Mi": 1024**2,
    "Gi": 1024**3,
    "Ti": 1024**4,
    "Pi": 1024**5,
    "Ei": 1024**6,
}
DECIMAL_UNITS = {
    "k": 1000,
    "M": 1000**2,
    "G": 1000**3,
    "T": 1000**4,
    "P": 1000**5,
    "E": 1000**6,
}


class GuardError(RuntimeError):
    pass


def quantity_bytes(value: str) -> int:
    match = QUANTITY_RE.fullmatch(value)
    if match is None:
        raise GuardError(f"unsupported Kubernetes storage quantity: {value}")
    number = float(match.group(1))
    suffix = match.group(2)
    if suffix == "m":
        multiplier = 0.001
    elif suffix in BINARY_UNITS:
        multiplier = BINARY_UNITS[suffix]
    elif suffix in DECIMAL_UNITS:
        multiplier = DECIMAL_UNITS[suffix]
    elif suffix is None:
        multiplier = 1
    else:
        raise GuardError(f"unsupported Kubernetes storage quantity suffix: {suffix}")
    result = number * multiplier
    if not math.isfinite(result) or result <= 0 or not result.is_integer():
        raise GuardError(f"storage quantity does not resolve to positive whole bytes: {value}")
    return int(result)


def unescape_label(value: str) -> str:
    return value.replace(r"\n", "\n").replace(r'\"', '"').replace(r"\\", "\\")


def parse_prometheus(text: str) -> list[tuple[str, dict[str, str], float]]:
    samples: list[tuple[str, dict[str, str], float]] = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = SAMPLE_RE.fullmatch(line)
        if match is None:
            continue
        name, raw_labels, raw_value = match.groups()
        try:
            value = float(raw_value)
        except ValueError:
            continue
        labels: dict[str, str] = {}
        if raw_labels:
            for label_match in LABEL_RE.finditer(raw_labels):
                labels[label_match.group(1)] = unescape_label(label_match.group(2))
        samples.append((name, labels, value))
    return samples


def metric_value(
    samples: list[tuple[str, dict[str, str], float]],
    name: str,
    required_labels: dict[str, str] | None = None,
) -> float | None:
    matches = []
    for metric_name, labels, value in samples:
        if metric_name != name:
            continue
        if required_labels and any(labels.get(key) != expected for key, expected in required_labels.items()):
            continue
        matches.append(value)
    if len(matches) > 1:
        raise GuardError(f"metric {name} matched more than one sample")
    return matches[0] if matches else None


def slot_name(labels: dict[str, str]) -> str | None:
    for key in ("slot_name", "slot", "slotname"):
        value = labels.get(key)
        if value:
            return value
    for value in labels.values():
        if value.startswith(HA_SLOT_PREFIX):
            return value
    return None


def slot_metrics(samples: list[tuple[str, dict[str, str], float]]) -> list[dict[str, Any]]:
    slots: dict[str, dict[str, Any]] = {}
    mapping = {
        "cnpg_pg_replication_slots_active": "active",
        "cnpg_pg_replication_slots_pg_wal_lsn_diff": "lag_bytes",
    }
    for metric_name, labels, value in samples:
        field = mapping.get(metric_name)
        if field is None:
            continue
        name = slot_name(labels)
        if name is None:
            continue
        entry = slots.setdefault(name, {"name": name, "active": None, "lag_bytes": None})
        if entry[field] is not None:
            raise GuardError(f"duplicate replication-slot metric {metric_name} for {name}")
        if field == "active":
            entry[field] = bool(value == 1.0) if math.isfinite(value) else None
        else:
            entry[field] = value if math.isfinite(value) and value >= 0 else None
    return [slots[name] for name in sorted(slots)]


def metric_snapshot(text: str) -> dict[str, Any]:
    samples = parse_prometheus(text)
    collector_up = metric_value(samples, "cnpg_collector_up")
    wal_size = metric_value(samples, "cnpg_collector_pg_wal", {"value": "size"})
    archive_ready = metric_value(
        samples,
        "cnpg_collector_pg_wal_archive_status",
        {"value": "ready"},
    )
    return {
        "collector_up": collector_up,
        "wal_bytes": wal_size,
        "archive_ready": archive_ready,
        "slots": slot_metrics(samples),
    }


def condition_true(cluster: dict[str, Any], condition_type: str) -> bool:
    for condition in cluster.get("status", {}).get("conditions", []):
        if condition.get("type") == condition_type:
            return condition.get("status") == "True"
    return False


def kubectl_json(namespace: str, resource: str, name: str) -> dict[str, Any]:
    command = ["kubectl", "-n", namespace, "get", resource, name, "-o", "json"]
    try:
        result = subprocess.run(
            command,
            check=True,
            capture_output=True,
            text=True,
            timeout=20,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        raise GuardError(f"read-only kubectl get failed for {resource}/{name}: {exc}") from exc
    try:
        parsed = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise GuardError(f"kubectl returned invalid JSON for {resource}/{name}") from exc
    if not isinstance(parsed, dict):
        raise GuardError(f"kubectl returned an invalid object for {resource}/{name}")
    return parsed


def metrics_url(ip: str) -> str:
    host = f"[{ip}]" if ":" in ip else ip
    return f"http://{host}:{METRICS_PORT}/metrics"


def read_metrics(ip: str) -> str:
    request = urllib.request.Request(metrics_url(ip), method="GET")
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            body = response.read(4 << 20)
            status = response.status
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise GuardError(f"CNPG metrics endpoint is unavailable for {ip}: {exc}") from exc
    if status != 200:
        raise GuardError(f"CNPG metrics endpoint returned HTTP {status} for {ip}")
    try:
        return body.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise GuardError(f"CNPG metrics endpoint returned non-UTF-8 data for {ip}") from exc


def collect_live(namespace: str, cluster_name: str) -> dict[str, Any]:
    cluster = kubectl_json(namespace, "clusters.postgresql.cnpg.io", cluster_name)
    spec = cluster.get("spec", {})
    status = cluster.get("status", {})
    instance_names = status.get("instanceNames")
    if not isinstance(instance_names, list) or not instance_names or not all(isinstance(v, str) for v in instance_names):
        raise GuardError("CNPG status.instanceNames is missing or invalid")

    instances: list[dict[str, Any]] = []
    for instance_name in sorted(instance_names):
        pvc = kubectl_json(namespace, "persistentvolumeclaim", instance_name)
        pod = kubectl_json(namespace, "pod", instance_name)
        pod_ip = pod.get("status", {}).get("podIP")
        if not isinstance(pod_ip, str) or not pod_ip:
            raise GuardError(f"pod {instance_name} has no podIP")
        request = pvc.get("spec", {}).get("resources", {}).get("requests", {}).get("storage")
        capacity = pvc.get("status", {}).get("capacity", {}).get("storage")
        if not isinstance(request, str) or not isinstance(capacity, str):
            raise GuardError(f"PVC {instance_name} storage request/capacity is unavailable")
        metrics = metric_snapshot(read_metrics(pod_ip))
        instances.append(
            {
                "name": instance_name,
                "pvc_request_bytes": quantity_bytes(request),
                "pvc_capacity_bytes": quantity_bytes(capacity),
                **metrics,
            }
        )

    return {
        "namespace": namespace,
        "cluster": cluster_name,
        "phase": status.get("phase"),
        "ready": condition_true(cluster, "Ready"),
        "continuous_archiving": condition_true(cluster, "ContinuousArchiving"),
        "instances_desired": spec.get("instances"),
        "ready_instances": status.get("readyInstances"),
        "current_primary": status.get("currentPrimary"),
        "instances": instances,
    }


def expected_slot(instance_name: str) -> str:
    return HA_SLOT_PREFIX + instance_name.replace("-", "_")


def add_reason(reasons: list[dict[str, Any]], code: str, **details: Any) -> None:
    reasons.append({"code": code, **details})


def evaluate(snapshot: dict[str, Any]) -> dict[str, Any]:
    reasons: list[dict[str, Any]] = []
    instances = snapshot.get("instances")
    if not isinstance(instances, list) or not instances:
        add_reason(reasons, "INSTANCE_METRICS_MISSING")
        instances = []

    desired = snapshot.get("instances_desired")
    ready_instances = snapshot.get("ready_instances")
    current_primary = snapshot.get("current_primary")
    names = [entry.get("name") for entry in instances if isinstance(entry, dict)]

    if snapshot.get("phase") != HEALTHY_PHASE:
        add_reason(reasons, "CLUSTER_PHASE_UNHEALTHY", phase=snapshot.get("phase"))
    if snapshot.get("ready") is not True:
        add_reason(reasons, "CLUSTER_READY_FALSE")
    if snapshot.get("continuous_archiving") is not True:
        add_reason(reasons, "CONTINUOUS_ARCHIVING_FALSE")
    if not isinstance(desired, int) or desired <= 0 or ready_instances != desired or len(instances) != desired:
        add_reason(
            reasons,
            "READY_INSTANCE_COUNT_MISMATCH",
            desired=desired,
            ready=ready_instances,
            observed=len(instances),
        )
    if not isinstance(current_primary, str) or current_primary not in names:
        add_reason(reasons, "CURRENT_PRIMARY_INVALID", current_primary=current_primary)

    by_name: dict[str, dict[str, Any]] = {}
    for entry in instances:
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
            add_reason(reasons, "INSTANCE_METRICS_INVALID")
            continue
        name = entry["name"]
        by_name[name] = entry
        capacity = entry.get("pvc_capacity_bytes")
        request = entry.get("pvc_request_bytes")
        wal_bytes = entry.get("wal_bytes")
        collector_up = entry.get("collector_up")
        archive_ready = entry.get("archive_ready")

        if not isinstance(capacity, int) or capacity <= 0 or request != capacity:
            add_reason(
                reasons,
                "PVC_CAPACITY_UNSETTLED",
                instance=name,
                request_bytes=request,
                capacity_bytes=capacity,
            )
            continue
        if collector_up != 1.0:
            add_reason(reasons, "CNPG_COLLECTOR_DOWN", instance=name, value=collector_up)
        if archive_ready != 0.0:
            add_reason(reasons, "WAL_ARCHIVE_BACKLOG", instance=name, ready=archive_ready)
        if not isinstance(wal_bytes, (int, float)) or not math.isfinite(float(wal_bytes)) or wal_bytes < 0:
            add_reason(reasons, "WAL_SIZE_UNAVAILABLE", instance=name)
        else:
            wal_fraction = float(wal_bytes) / capacity
            entry["wal_fraction"] = wal_fraction
            if wal_fraction >= MAX_WAL_FRACTION:
                add_reason(
                    reasons,
                    "WAL_FRACTION_EXCEEDED",
                    instance=name,
                    wal_bytes=wal_bytes,
                    capacity_bytes=capacity,
                    fraction=wal_fraction,
                    limit=MAX_WAL_FRACTION,
                )

        slots = entry.get("slots")
        if not isinstance(slots, list):
            add_reason(reasons, "REPLICATION_SLOT_METRICS_MISSING", instance=name)
            continue
        for slot in slots:
            if not isinstance(slot, dict):
                add_reason(reasons, "REPLICATION_SLOT_METRICS_INVALID", instance=name)
                continue
            slot_id = slot.get("name")
            if not isinstance(slot_id, str) or not slot_id.startswith(HA_SLOT_PREFIX):
                continue
            active = slot.get("active")
            lag_bytes = slot.get("lag_bytes")
            if active is False and isinstance(lag_bytes, (int, float)) and math.isfinite(float(lag_bytes)):
                lag_fraction = float(lag_bytes) / capacity
                if lag_fraction >= MAX_INACTIVE_SLOT_LAG_FRACTION:
                    add_reason(
                        reasons,
                        "INACTIVE_HA_SLOT_LAG_EXCEEDED",
                        instance=name,
                        slot=slot_id,
                        lag_bytes=lag_bytes,
                        capacity_bytes=capacity,
                        fraction=lag_fraction,
                        limit=MAX_INACTIVE_SLOT_LAG_FRACTION,
                    )

    if isinstance(current_primary, str) and current_primary in by_name:
        primary = by_name[current_primary]
        primary_slots = {
            slot.get("name"): slot
            for slot in primary.get("slots", [])
            if isinstance(slot, dict) and isinstance(slot.get("name"), str)
        }
        for name in names:
            if not isinstance(name, str) or name == current_primary:
                continue
            slot_id = expected_slot(name)
            slot = primary_slots.get(slot_id)
            if slot is None:
                add_reason(reasons, "PRIMARY_HA_SLOT_MISSING", slot=slot_id)
            elif slot.get("active") is not True:
                add_reason(reasons, "PRIMARY_HA_SLOT_INACTIVE", slot=slot_id)

        stale_primary_slot = expected_slot(current_primary)
        for name, entry in by_name.items():
            if name == current_primary:
                continue
            slot_ids = {
                slot.get("name")
                for slot in entry.get("slots", [])
                if isinstance(slot, dict)
            }
            if stale_primary_slot in slot_ids:
                add_reason(
                    reasons,
                    "STALE_PRIMARY_HA_SLOT",
                    instance=name,
                    slot=stale_primary_slot,
                )

    return {
        "status": "PASS" if not reasons else "BLOCK",
        "namespace": snapshot.get("namespace"),
        "cluster": snapshot.get("cluster"),
        "current_primary": current_primary,
        "thresholds": {
            "max_wal_fraction": MAX_WAL_FRACTION,
            "max_inactive_slot_lag_fraction": MAX_INACTIVE_SLOT_LAG_FRACTION,
        },
        "reasons": reasons,
        "instances": instances,
    }


def load_snapshot(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise GuardError(f"cannot read snapshot safely: {exc}") from exc
    if not isinstance(value, dict):
        raise GuardError("snapshot root must be a JSON object")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Read-only Authentik CloudNativePG safety preflight. Any incomplete or unsafe "
            "evidence blocks maintenance eligibility."
        )
    )
    parser.add_argument("--namespace", default=DEFAULT_NAMESPACE)
    parser.add_argument("--cluster", default=DEFAULT_CLUSTER)
    parser.add_argument("--snapshot", type=Path, help="evaluate an offline JSON snapshot instead of reading Kubernetes")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        snapshot = load_snapshot(args.snapshot) if args.snapshot else collect_live(args.namespace, args.cluster)
        outcome = evaluate(snapshot)
    except GuardError as exc:
        print(json.dumps({"status": "BLOCK", "reasons": [{"code": "EVIDENCE_UNAVAILABLE", "detail": str(exc)}]}, sort_keys=True))
        return 1
    print(json.dumps(outcome, sort_keys=True, separators=(",", ":")))
    return 0 if outcome["status"] == "PASS" else 2


if __name__ == "__main__":
    raise SystemExit(main())
