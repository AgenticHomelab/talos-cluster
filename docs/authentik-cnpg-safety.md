# Authentik CloudNativePG WAL safety gate

This document records the temporary deterministic safety gate introduced after
the August 2026 Authentik PostgreSQL WAL exhaustion incident.

The gate is deliberately narrower than a full monitoring stack. Its immediate
purpose is to prevent routine maintenance or another merge canary from starting
while the Authentik CloudNativePG cluster has evidence of dangerous WAL retention,
replication-slot residue, missing metrics, or degraded health.

It is **read-only**. It must never mutate Kubernetes, PostgreSQL, Flux, PVCs,
replication slots, or lifecycle state.

## Incident evidence

The recovered cluster uses three 30 GiB Longhorn PVCs. After recovery, the
primary and one replica carried roughly 600 MiB of `pg_wal`, while
`authentik-postgres-3` still carried roughly 20.2 GiB. That replica also exposed
an inactive `_cnpg_authentik_postgres_2` HA-slot record with roughly 20.15 GiB of
lag even though `authentik-postgres-2` was the current primary.

The effective PostgreSQL setting `max_slot_wal_keep_size` was `-1`, so retained
WAL was not bounded by PostgreSQL. Continuous archiving and scheduled backups
were healthy; archive backlog was not identified as the incident cause.

The post-incident classification was a combination of failover/timeline recovery
pressure and unbounded HA-slot WAL retention while replicas were lagging or
recovering. The 30 GiB expansion provided recovery runway but did not eliminate
the retention mechanism.

## Guard

Run:

```bash
python3 scripts/automation/authentik_cnpg_safety_guard.py
```

The live path performs only:

- `kubectl get` of the Authentik CNPG Cluster, its instance Pods and PVCs; and
- unauthenticated read-only HTTP GET requests to each CNPG instance metrics
  endpoint on port `9187`.

For regression tests and incident replay, an offline snapshot can be supplied:

```bash
python3 scripts/automation/authentik_cnpg_safety_guard.py \
  --snapshot /path/to/snapshot.json
```

Exit codes are:

- `0`: deterministic evidence is safe enough to continue the maintenance
  preflight;
- `2`: deterministic evidence is present but violates a safety threshold; and
- `1`: evidence could not be collected or parsed safely.

Every non-zero result blocks maintenance eligibility. No caller may interpret
missing evidence as success.

## Temporary safety thresholds

The guard currently blocks when any instance has `pg_wal` at or above **50% of
its PVC capacity**. This is intentionally more conservative than an operational
capacity alert because the current CNPG `volume_size` metrics are `NaN` and the
full PostgreSQL filesystem usage is not available without `exec`.

It also blocks an inactive `_cnpg_` HA slot when its exported retained-WAL/LSN
lag is at or above **10% of that instance PVC capacity**.

The guard additionally blocks when:

- the Cluster is not in `Cluster in healthy state`;
- the `Ready` or `ContinuousArchiving` condition is not true;
- `readyInstances` differs from desired instances;
- any PVC request and capacity are not equal and settled;
- `cnpg_collector_up` is not `1`;
- `archive_status{value="ready"}` is not zero;
- WAL-size or replication-slot metrics needed by the gate are unavailable;
- the primary is missing an active HA slot for a current standby; or
- a standby exposes an HA slot named for the **current primary**, which is a
  stale-role indicator after a switchover/failover.

These thresholds are automation-safety gates, not final alert policy. They are
fixed in code and covered by regression tests so an automation caller cannot
weaken them with command-line flags.

## Maintenance integration

Until a dedicated monitoring/alerting stack is deployed, this guard is a
mandatory preflight before starting another R1 or R2 maintenance lifecycle item.
A failed guard must prevent `DISCOVERED -> VALIDATED -> ELIGIBLE` from reaching
merge eligibility and must not trigger an automatic repair.

The current scheduler/autonomous R1 work remains inactive. This safety gate does
not itself activate a scheduler or grant any merge, Kubernetes, Flux or database
write authority.

## Why no retention cap is applied yet

PostgreSQL `max_slot_wal_keep_size` should eventually be bounded explicitly, but
introducing a cap while a replica still carries a large stale-like HA-slot lag
can invalidate required WAL and turn a recoverable replica into one that needs
reinitialization.

Therefore the order is:

1. deploy and run the read-only safety guard;
2. require the current replica/slot residue to converge or diagnose it explicitly;
3. measure non-WAL filesystem usage and representative WAL generation;
4. choose and validate an explicit retention budget;
5. add persistent WAL/PVC/CNPG health alerting; and
6. only then remove the temporary incident diagnostics RBAC.

A future retention limit must be based on measured headroom, recovery time and
WAL generation rather than selecting an arbitrary number from an example.

## Scope

This gate is specifically for the Authentik CloudNativePG cluster because that
cluster is a dependency of the Hermes automation plane and was the source of the
incident. A later observability phase may generalize the same signals to all
CloudNativePG clusters and add durable alert delivery.
