# Talos metrics reliability investigation: 2026-10-15

Read-only production observations plus a disposable workstation reproduction.
No production restart, outage, credential access, configuration or deployment was
performed. Base Talos main: `0b54595fa57fea29478e9634e9a2065c13e5f307`;
OCI main: `0d042152df76f4b184ec8bf613b76aa68f76cfe7`.
Earlier production exercise evidence remains in [the dated audit](talos-metrics-resilience.md).

## Dashboard acceptance supersedes the earlier blocker

The operator reports accepted OCI PR 56, merge
`0d042152df76f4b184ec8bf613b76aa68f76cfe7`: first scoped apply `ok=6 changed=1
failed=0`, repeat `ok=6 changed=0 failed=0`, and visual confirmation of real node,
Pod, Deployment, scrape-health and freshness panels. The hosted-CI exception was
explicitly approved on that PR; it does not authorize later merges or policy edits.
Read-only follow-up found both native stored dashboard resources and the unchanged
loopback datasource. No agent browser check or repeat apply is claimed. The
11:10–11:15 EEST graph gap is historical missing data, consistent with the earlier
controlled interruption. Configured resources are not actual CPU/memory usage;
kubelet usage remains excluded. See the OCI dashboard runbook/acceptance PR.

## WAL root cause and upstream status

[Alloy #5320](https://github.com/grafana/alloy/issues/5320) reports silently dropping
samples older than process startup, including receive_http input. Its maintainer
points to the upstream remote-write savepoint proposal.
[Alloy #4469](https://github.com/grafana/alloy/issues/4469) contains two distinct
cases: unexplained failure after receiver recovery, and endpoint-switch replay.
The maintainer describes the latter as expected upstream behavior. Both issues
were open at inspection. Neither thread proves the no-restart failure for this
configuration; the isolated running-process case below tests it directly.

Exact source path for v1.20.1 (revision `95e12cf`):

1. [remote_write.go](https://github.com/grafana/alloy/blob/v1.20.1/internal/component/prometheus/remotewrite/remote_write.go)
   opens native WAL storage, then Prometheus remote storage. Its own `startTime`
   callback returns zero; that callback is **not** the watcher's replay boundary.
2. [go.mod](https://github.com/grafana/alloy/blob/v1.20.1/go.mod) pins the Grafana
   Prometheus fork at `6ac45be9754c` (replacement pseudo-version
   `v1.8.2-0.20260917201616-6ac45be9754c`).
3. That dependency's [Watcher.loop/Run/readSegment](https://github.com/grafana/prometheus/blob/6ac45be9754c/tsdb/wlog/watcher.go)
   sets its start timestamp to current time, reconstructs series from checkpoint
   and old segments, ignores sample records from non-tailed segments and filters
   tailed samples to timestamps newer than the watcher start. Loading checkpoint
   identities therefore does not imply forwarding historical sample records.
4. Alloy's [WAL replay](https://github.com/grafana/alloy/blob/v1.20.1/internal/static/metrics/wal/wal.go)
   restores series references/labels and last timestamps for append/GC state. It
   does not bypass the independent remote writer's historical-sample filter.
5. [QueueManager.Stop/shards.stop](https://github.com/grafana/prometheus/blob/6ac45be9754c/storage/remote/queue_manager.go)
   attempts a flush, then cancels outstanding work after Alloy's fixed one-minute
   `remoteFlushDeadline`. A healthy process exit is not durable delivery when its
   receiver remains unavailable. Kubernetes' existing 60s grace can additionally
   end that flush; the isolated test allows 75s and still reproduces missing data.
6. WAL truncation runs hourly in production. The cutoff uses lowest-sent minus
   minimum keepalive, capped by current time minus maximum keepalive. Checkpointing
   and segment deletion bound disk retention; these are not durable remote-write
   savepoints. The short reproduction uses the same 1h/5m/8h retention settings,
   so retention expiry is not its cause.

This is a reproduced upstream restart/replay limitation consistent with #5320 and
the relevant #4469 discussion, not evidence of Longhorn corruption or Nginx loss.
[Prometheus proposal 72](https://github.com/prometheus/proposals/pull/72) was merged
on 2026-07-09, but an accepted proposal is not a shipped Alloy implementation.
The latest stable Alloy release returned by GitHub was still **v1.20.1** during
inspection; no released fix was established. Its WAL record-type replay fix
[#7180](https://github.com/grafana/alloy/pull/7180) concerns metadata/empty records,
not a removal of this startup timestamp boundary. Do not advertise it as this fix.

## Isolated reproduction and operational mitigation

The one-off Podman experiment used native Alloy v1.20.1 and VictoriaMetrics
v1.154.0 with synthetic self-scrapes, loopback networking and temporary storage.
Its fixed-version reproducer was removed during the 2026-10-17 test cleanup;
the completed evidence below is retained. Repeating or extending this experiment
requires a new isolated plan against the relevant upstream behavior. It is not
part of CI or a production durability check.

Expected scrape seconds come from the native highest-input gauge, which truncates
milliseconds. Raw receiver export preserves exact millisecond timestamps; comparison
matches those points to the recorded seconds for this single 1 Hz series. No range
interpolation or queue-zero inference is used. Evidence is intentionally limited
to the checked fixture series, not universal losslessness or storage crash safety.

The three requested boundaries are tested, with an additional distinction between
starting a new process after receiver recovery and allowing the old process to drain:

- Receiver unavailable while Alloy stays running: checked buffered timestamps must
  arrive after recovery.
- Graceful Alloy restart while receiver unavailable: reproduce missing older points
  despite retained WAL and resumed fresh delivery.
- Receiver restored before starting a replacement process: distinguish receiver
  availability from preservation of the original writer's state.
- Receiver restored while the original process remains running, checked points
  exported, then graceful restart: test the supported operational mitigation.

The runner exits successfully only when it reproduces the known loss in restart
cases and observes checked timestamp recovery in the live-process cases. A green
runner is **confirmation of the limitation**, not a production durability pass.
The completed isolated run recorded the following results.

| Case | Checked outage seconds recovered | Graceful exit / stop duration |
| --- | --- | --- |
| Original process kept running | 8/8 | No restart |
| Restart while receiver down | 0/8 | exit 0 / 60.095s |
| Receiver restored before replacement starts | 0/8 | exit 0 / 60.096s |
| Original process drains before restart | 8/8 | exit 0 / 0.078s |

All four cases resumed fresh delivery, retained the WAL directory inode and
observed pending zero during recovery with failed zero. The continuously running
1 Hz fixture had one newly pending sample in its final snapshot; this does not
change the raw-timestamp comparison. Other final pending snapshots were zero.
Final failure counters belong to the current process; replacement resets them,
so zero does not rule out old-process shutdown drops. This reproduces missing historical points
without storage corruption, credentials, TLS, Nginx, Tailscale or Kubernetes.
The initial fixture needed its accelerated scrape timeout corrected; the timestamp
comparison also had to respect the native gauge's integer-second precision.
A later polling wait was shortened to avoid aliasing a 1 Hz scrape. Those fixture
failures are not production findings; only the completed timestamp run is evidence.

Smallest current mitigation: avoid replacing/reconfiguring the writer during a
transport incident. Restore the existing route/receiver without restarting Alloy;
verify stored buffered timestamps and fresh samples, pending/lag drainage, then
schedule any approved collector rollout. Queue zero alone is insufficient. Longer
retention, more shards, sample-age limits or longer termination grace do not remove
the startup filter; a process crash during an outage remains an accepted risk,
not solved by this operational rule. Do not add a WAL replay helper or local fork.

For a later supported fix: require an actual released Alloy implementation and
release notes/source proving restart-from-savepoint behavior, rerun these exact
raw-timestamp cases (plus crash/retention boundaries) with the candidate pinned
image, validate its official chart/security/resources and existing dashboards,
then separately review upgrade/rollback and bounded production acceptance. No
upgrade or changed production configuration is part of this investigation.

## EOF observations and limits

At 08:57:25 UTC, bounded `kubectl logs --since=2h --tail=600` inspection of the
current Alloy process found 18 EOF warnings, first 08:15:01 and last 08:57:00.
Seventeen occurred at second 00 and one at second 01; successive intervals were
60–300s, all multiples of one minute. This is a cadence correlation, **not proof
of a particular timer closing a connection**. Existing 60s scrapes and batching
also make requests periodic. The earlier six-hour 157-warning baseline remains
valid; this shorter post-replacement sample is not a comparable six-hour rate.

Bounded egress logs (105/99 lines) and operator logs had no error/reconnect/closed/
timeout signals; all three component Pod identities/restart counts were unchanged.
Namespace events showed only an ArtifactUpToDate event, no warning event. Nginx,
VM, Grafana, host Alloy and tailscaled had unchanged process identities; Nginx had
no service journal activity in the requested two hours. Receiver `access_log off`
was confirmed privately and its current error log was empty. Therefore response
statuses, request durations and connection-close ownership cannot be correlated
from existing receiver logs. No protected request logging or packet capture was
introduced. A zero error log is not proof that Nginx did not close idle connections.

At that observation both Talos jobs were up=1, ages approximately 54s/28s, OCI host
up=1, one-hour failed increase=0 and sampled pending maximum=0. Retry increase was
11,177 sample attempts; it does not count distinct lost samples. No error-level,
listed 400/401/403/413/429/500 or x509 signals were found in the bounded Alloy logs.
These observations do not attribute EOF to service shutdown or prove a Nginx,
Tailscale or Go idle-reuse bug. Nginx's 30s keepalive versus sparse traffic is a
hypothesis; native clients normally handle known idle closes. **No fix is justified
by present evidence, and no keepalive/queue/Tailscale settings were changed.**

Suggested bounded follow-up (not an installed alert or new daemon): take three
read-only queue/freshness observations across 5–10 minutes when symptoms worsen;
correlate finite Alloy/proxy logs and existing receiver error/journal metadata in
UTC. Escalate immediately for TLS/auth errors, increasing failed/dropped/WAL-error
counters, or storage health warnings; investigate if sample age >180s on two checks,
pending fails to drain for 5m, or backlog approaches retention/capacity. Track EOF
counts and retry rate relative to the same scrape volume/window, not warning count
alone. Persistent symptoms may justify a separately approved metadata-only
connection experiment or upstream report, never logging credentials/payloads or
restarting the collector during a backlog.

A second bounded log check at approximately 09:12 UTC found 25 EOF warnings in
63 returned lines, with no HTTP 4xx/5xx, TLS-verification or error-level signals.
This confirms recurrence without establishing which peer closed the connections.
The receiver's missing access-duration data remains a limit, not permission to
change production logging. No production changes were made during either check.

At approximately 09:12 UTC a separate local telemetry read caught 123 pending
samples while both jobs remained up/fresh and failed/corruption counters were zero.
A second snapshot caught 415 pending. Fifteen finite local telemetry observations
at 09:13:33–09:13:51 UTC then all reported pending=0 and failed=0, with a recent
highest-sent timestamp. The queue drained without intervention. A single
instantaneous value is not a persistent-backlog diagnosis or evidence of loss.
