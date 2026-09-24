# 0002 — Migrate over the APIs, not by copying data directories

Status: accepted

## Context

VictoriaMetrics and VictoriaLogs both store data in a directory (`-storageDataPath`) made of immutable
parts, and both can produce a hardlink **snapshot** of it. Copying that directory to the target is the
fastest way to move a large dataset: no query layer, no serialisation, no per-sample work. It is the
obvious first idea, and for a large enough dataset it is the right one.

The alternative is to move data through the HTTP APIs: `vmctl vm-native` for metrics, and export/import
for logs.

## Decision

Migrate over the **APIs**. `vmctl vm-native` for metrics; `/select/logsql/query` →
`/insert/jsonline` for logs.

## Why: the target is already live

The target GKE cluster runs its own VictoriaMetrics and VictoriaLogs, collecting its own metrics and
logs from the moment it exists — the production situation this lab imitates. That single fact rules out
the filesystem approach, because **restoring a snapshot is a whole-directory replace, not a merge**. The
documented procedure is to remove everything under `-storageDataPath` and put the snapshot's contents
there, and `vmrestore` refuses to write into a directory a running instance owns, so the target must be
stopped first. Doing that would destroy exactly the data the target had been collecting.

There is no "merge two data directories" operation. The requirement to preserve the target's own data
and the filesystem approach are mutually exclusive.

## Why: VictoriaLogs has no such tooling anyway

Even setting the merge problem aside, the log half has no supported path — and this is worth stating
precisely, because there *are* VictoriaLogs command-line tools and it would be easy to assume one of them
does the job.

**`vmctl` has no VictoriaLogs mode.** Its subcommands are `opentsdb`, `influx`, `remote-read`,
`prometheus`, `mimir`, `thanos`, `vm-native` and `verify-block`. All of them write to VictoriaMetrics.

**`vlogscli` cannot write at all.** It ships in the `vlutils` package and is the officially recommended
interactive client — "similar to psql for PostgreSQL". Its entire flag surface is querying:
`-datasource.url`, `-tail.url`, output modes, query history, TLS and auth. There is no insert URL, no
import mode, no write path of any kind. It is the right tool for *inspecting* either side of a migration
(see the README) and no help in performing one.

**`vlagent` replicates forward, not backward.** It can fan out newly collected logs to several
VictoriaLogs instances, which is a useful cutover tool and does nothing for history.

**The vendor confirms both gaps.** The [VictoriaLogs roadmap](https://docs.victoriametrics.com/victorialogs/roadmap/)
lists as future work:

- "Migration tooling from other logging systems, similar to vmctl" (issue #521)
- "Backup, restore and backup manager tooling, on top of the existing storage snapshots" (issue #123)

So this is not an absence of evidence: migration tooling and backup/restore tooling are both **planned
and unshipped**. Until they exist, the export/import path this lab uses is the only supported way to move
log history between instances, and a filesystem migration would mean hand-copying hardlink snapshot trees
off a stopped instance plus PVC → object storage → PVC plumbing plus version-locked on-disk formats —
more moving parts than the API path, not fewer.

**When that changes, revisit this decision.** If issue #521 ships a `vmctl`-style log migrator, it very
likely supersedes `migrator migrate-logs` entirely; if #123 ships backup/restore, the hybrid described at
the end of this ADR becomes far more attractive.

## Why this also makes verification stronger

Migrating through the APIs means the data has to be *addressable* by query on both sides, which is what
lets `task verify` diff the two databases sample by sample. A filesystem restore would only support
"the directories are byte-identical", which says nothing useful once the target holds its own data too.

## Consequences

**The metric half is idempotent; the log half is not.** This asymmetry is worth knowing before running
anything twice:

- Both VictoriaMetrics instances run with `-dedup.minScrapeInterval=1ms`, so re-importing a sample that
  is already present collapses to one sample. `task migrate` is safe to re-run for metrics. Without that
  flag a second run would double every migrated sample and verification would report what looks like
  corruption.
- VictoriaLogs deduplicates nothing and cannot delete by query. A second log migration would leave two
  copies of every line, permanently. So `migrator migrate-logs` checks the target first and **refuses to run**
  unless `MIGRATE_FORCE=1`. The same guard exists in `migrator seed` for the same reason.

**Log streams have to be reconstructed deliberately.** The export includes `_stream` (a rendered string
like `{service="checkout"}`) and `_stream_id` (the source's storage identity), neither of which should be
stored on the target. The import therefore discards both via `ignore_fields` and rebuilds streams from
`_stream_fields`, whose value is **discovered at runtime** from the source's
`/select/logsql/stream_field_names`. It cannot be hardcoded: the seeded dataset's streams are
`{service,dataset}` while the collector's container logs use Kubernetes metadata, and both must survive.
Dropping the derived fields server-side also means exported lines are forwarded byte for byte with no
client-side parsing.

**VictoriaMetrics' own `vm_*` metrics are deliberately not migrated** (`--vm-native-filter-match={__name__!~"vm_.*"}`).
Both clusters produce them natively, so carrying them over would interleave two clusters'
self-monitoring into one set of series and make the official VM dashboards read nonsense.

**Retention is a silent trap for backdated data.** Both stores drop samples and log entries whose
timestamps fall outside the retention window **at ingest time**, from the writer's point of view without
error. Retention is set to 30d on both sides and `migrator seed` refuses to run with `SEED_DAYS >= 30`, because
a seed that appears to succeed while storing nothing is a genuinely confusing failure.

## What a real 123-million-line migration changed about this design

The design above was written for this lab's topology, where the two clusters are joined by a private VPN.
It was then used to migrate ~123M log lines between two production clusters that had **no** private path,
over `kubectl port-forward`. Three things broke, and the fixes are in the lab because they improve the
general case rather than just the improvised one.

**A tunnelled export truncates silently.** A window holding 346,365 lines returned 70,748 — and did so
through `curl` as well as Go, so it is the transport rather than any one client. Go surfaces the cut as
`chunked line ends with bare LF`; `curl` simply stops early and reports success, which is worse. Nothing
in the original design would have noticed: it compared only the **grand total** at the end, and treated a
mismatch as a warning. It lost 688 lines before anyone looked.

So `migrate-logs` now **counts every window on the source before exporting it, and compares that against
what was actually forwarded**. Per-window comparison is the load-bearing check; a grand total tells you
that something is missing but never where, and cannot stop you continuing past a hole. This matters even
over a VPN — a window large enough to strain a timeout fails the same way.

**Windows have to be sized by content, not by clock.** Log volume varies enormously: in the real dataset
one two-hour window held 2 lines and another held 346,365, and a single day held 21M. Any fixed step is
therefore wrong everywhere except by accident. Windows are now **bisected on time until each holds fewer
than `MIGRATE_MAX_WINDOW_LINES`** (default 20,000, an order of magnitude under the ~70-80k where
truncation began). 2,698 splits were needed on the real data; afterwards, zero truncations.

**Retrying a window that failed late duplicates all of it.** The window that killed the first run failed
*after* streaming most of its data, so each of four attempts imported ~346k lines — leaving roughly four
copies, ~1.02M duplicate lines, permanently, because VictoriaLogs cannot delete by query. Bisection is
also the mitigation here: a ≤20,000-line window bounds what a late failure can duplicate.

**Loss is tolerated but never silent.** A truncated or failed window is recorded and the run continues —
halting a multi-hour transfer over a few lines is the wrong trade — but everything missed is counted and
summarised, so the outcome is a number rather than an impression. Ten *consecutive* failures abort, since
that is no longer occasional loss but something broken, and it prints the timestamp to resume from.

**Compression is worth more than it looks.** Kubernetes log lines repeat the same pod metadata on every
entry and compress **29x** in practice (measured: 5.14 MB of JSON to 177 KB). The read side already
benefited, because Go's transport requests gzip and decompresses transparently; the write side was sending
raw JSON, which over a 35 Mbps link was the difference between ~8.5 hours and ~35 minutes of transfer.
Imports are now gzipped.

**The timestamp format put a floor under the bisection.** Boundaries were formatted to whole seconds, so a
sub-second window came out with `start == end` and matched nothing — meaning bisection silently stopped
working below one second rather than failing. On the busiest day a burst of ~48,000 lines inside 42
seconds therefore had to be exported oversized 606 times. It never truncated, but the safety margin had
been spent by an arbitrary limit. Boundaries now carry **millisecond** precision and the floor is 100ms.
The format and the floor have to move together, which is why both are commented at their definitions.

## The hybrid worth knowing about

If the dataset were large enough that API throughput hurt, there is a way to get both properties:
`vmbackup` → object storage → `vmrestore` into a **temporary** VMSingle in the target cluster, then
`vmctl vm-native` from that temporary instance into the real target. Bulk transfer happens at filesystem
speed; the merge still happens through the API. Not implemented here — it doubles the moving parts for no
benefit at this data volume — but it is the answer when the volume changes the tradeoff.

## Alternatives rejected

- **Snapshot + `vmrestore` directly into the target** — fastest, but replaces the target's storage and so
  destroys the data it had been collecting. Incompatible with a live target.
- **Re-point the source's `vmagent`/collector at the target and wait** — trivially safe, but it migrates
  no history at all: only data written after the switch. The whole subject here is the old data.
- **`vlagent` fan-out replication** — replicates new logs to two destinations, which is a good cutover
  tool and no help for backfill.
