package main

// `migrator migrate-logs` moves logs from the SOURCE VictoriaLogs to the TARGET, over the cross-cloud VPN.
//
// WHY THIS CODE EXISTS AT ALL
//
// No tool does this yet, and it is worth being precise about which tools exist and why none of them fit:
//
//	vmctl      migrates VictoriaMetrics data only. Subcommands: opentsdb, influx, remote-read, prometheus,
//	           mimir, thanos, vm-native, verify-block. There is no VictoriaLogs mode.
//	vlogscli   reads only. It is the interactive LogsQL client ("psql for VictoriaLogs") and its whole flag
//	           surface is querying — no insert URL, no import mode, no write path.
//	vlagent    replicates NEWLY COLLECTED logs to several destinations. A cutover tool, useless for history.
//
// VictoriaMetrics' own roadmap still lists "migration tooling ... similar to vmctl" (#521) and
// "backup, restore and backup manager tooling" (#123) as future work, so the gap is confirmed rather than
// merely unfound. Until one of those ships, the log half is export-and-reimport over the HTTP APIs:
//
//	source /select/logsql/query  -->  JSON lines  -->  target /insert/jsonline
//
// PRESERVING LOG STREAMS
//
// A log entry belongs to a STREAM identified by a set of fields, and streams must survive the move or the
// target's data is subtly wrong — same lines, different grouping. Two details make that work:
//
//  1. _stream_fields is set to the union of the stream field names actually present on the SOURCE,
//     discovered at runtime via /select/logsql/stream_field_names. It cannot be hardcoded, because the two
//     kinds of logs here have different stream fields: the seeded dataset uses {service,dataset}, while the
//     collector's container logs use Kubernetes metadata. Each entry's stream is then rebuilt from
//     whichever of those fields it actually carries.
//
//  2. ignore_fields=_stream,_stream_id drops the two DERIVED fields the export includes. _stream is a
//     rendered string (`{service="checkout"}`) rather than real fields, and _stream_id belongs to the
//     source's storage — the target must mint its own. Discarding them server-side means exported lines are
//     forwarded BYTE FOR BYTE with no parsing, which is simpler and faster than rewriting every line.
//
// IDEMPOTENCY — THE ASYMMETRY WORTH KNOWING
//
// The metric half of this migration is safely repeatable: re-importing an identical sample collapses to one
// sample because both stores run -dedup.minScrapeInterval=1ms.
//
// Logs have no such property. VictoriaLogs deduplicates nothing and cannot delete by query, so running this
// twice leaves two copies of every line and no way to remove one — and verification would then report a
// mismatch that looks like corruption rather than a repeated run. Hence the guard: if the target already
// holds the migrated dataset, this refuses to run unless MIGRATE_FORCE=1.
//
// Environment:
//
//	SOURCE_VL_URL   source VictoriaLogs base URL, reached over the VPN
//	TARGET_VL_URL   target VictoriaLogs base URL (in-cluster)
//	MIGRATE_START   RFC3339 start of the window to migrate (inclusive)
//	MIGRATE_END     RFC3339 end of the window to migrate (exclusive) — the migration cutoff
//	MIGRATE_FORCE   set to 1 to migrate even if the target already holds migrated logs
//	CHUNK_LINES     log lines per import request (default 5000)

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"
)

// exitAlreadyMigrated is distinct from a generic failure: nothing is wrong, the work was already done.
const exitAlreadyMigrated = 3

func runMigrateLogs() (int, error) {
	sourceURL, err := mustEnv("SOURCE_VL_URL")
	if err != nil {
		return 1, err
	}
	targetURL, err := mustEnv("TARGET_VL_URL")
	if err != nil {
		return 1, err
	}
	sourceURL = strings.TrimRight(sourceURL, "/")
	targetURL = strings.TrimRight(targetURL, "/")
	registerRemote(sourceURL)

	// What to move. Defaults to everything, which is what the lab wants; a real migration almost always
	// wants a subset, e.g. one namespace.
	query := os.Getenv("MIGRATE_QUERY")
	if query == "" {
		query = "*"
	}

	// Fields stamped onto every imported entry, as `name=value` pairs. Provenance is the usual reason:
	// once two clusters' logs share one database, "where did this line come from?" has no answer unless
	// something recorded it at import time.
	extraFields := os.Getenv("MIGRATE_EXTRA_FIELDS")

	// The already-migrated guard, expressed as a LogsQL filter. EMPTY DISABLES IT.
	//
	// The guard exists because VictoriaLogs cannot deduplicate or delete by query, so a second run leaves
	// permanent duplicates. But that is a tradeoff, not a law: an operator who accepts duplicates (say,
	// resuming a transfer that died halfway) is better served by a tool that proceeds than one that
	// refuses. So it is opt-in rather than assumed, and the lab sets it explicitly.
	guardQuery := os.Getenv("MIGRATE_GUARD_QUERY")

	// Window size. Smaller windows mean more requests but a more resumable transfer — which matters when
	// the data path is a `kubectl port-forward`, a single TCP stream through the API server that drops
	// under sustained load.
	stepHours, err := envInt("MIGRATE_STEP_HOURS", 24)
	if err != nil {
		return 1, err
	}
	if stepHours < 1 {
		return 1, fmt.Errorf("MIGRATE_STEP_HOURS must be at least 1, got %d", stepHours)
	}

	// Retries per window. Default 0 so a failure in the lab is a failure, not a silent repair. Raise it
	// for a transfer over a flaky path — but note each retry re-sends the whole window, so any portion
	// already imported before the failure is duplicated.
	windowRetries, err := envInt("MIGRATE_WINDOW_RETRIES", 0)
	if err != nil {
		return 1, err
	}

	// Maximum lines to export in ONE request. Windows holding more are bisected until they fit.
	//
	// THIS EXISTS BECAUSE OF A MEASURED FAILURE, not caution. Exporting a large result set through a
	// `kubectl port-forward` silently TRUNCATES: a window holding 346,365 lines returned only 70,748,
	// and the same window truncated through curl too, so it is the tunnel rather than any one client.
	// Go surfaces the cut mid-stream as "chunked line ends with bare LF"; curl simply stops early and
	// says nothing, which is worse.
	//
	// 20k keeps each export an order of magnitude below the ~70-80k where truncation began.
	maxWindowLines, err := envInt("MIGRATE_MAX_WINDOW_LINES", 20000)
	if err != nil {
		return 1, err
	}
	if maxWindowLines < 1 {
		return 1, fmt.Errorf("MIGRATE_MAX_WINDOW_LINES must be at least 1, got %d", maxWindowLines)
	}

	startRaw, err := mustEnv("MIGRATE_START")
	if err != nil {
		return 1, err
	}
	endRaw, err := mustEnv("MIGRATE_END")
	if err != nil {
		return 1, err
	}
	start, err := time.Parse(time.RFC3339, startRaw)
	if err != nil {
		return 1, fmt.Errorf("MIGRATE_START %q is not RFC3339: %w", startRaw, err)
	}
	end, err := time.Parse(time.RFC3339, endRaw)
	if err != nil {
		return 1, fmt.Errorf("MIGRATE_END %q is not RFC3339: %w", endRaw, err)
	}
	if !start.Before(end) {
		return 1, fmt.Errorf("MIGRATE_START (%s) must be before MIGRATE_END (%s)", startRaw, endRaw)
	}
	start, end = start.UTC(), end.UTC()

	chunkLines, err := envInt("CHUNK_LINES", 5000)
	if err != nil {
		return 1, err
	}

	logf("==> source : %s", sourceURL)
	logf("==> target : %s", targetURL)
	logf("==> window : %s .. %s (step %dh)", rfc(start), rfc(end), stepHours)
	logf("==> filter : %s", query)
	if extraFields != "" {
		logf("==> tagging imported entries with: %s", extraFields)
	}

	if guardQuery != "" {
		already, err := countLogs(targetURL, guardQuery, start, end)
		if err != nil {
			return 1, err
		}
		if already > 0 && !envIs("MIGRATE_FORCE", "1") {
			logf("")
			logf("==> REFUSING TO RUN: the target already holds %d lines matching %q.", already, guardQuery)
			logf("    VictoriaLogs cannot deduplicate or delete by query, so migrating again would leave a")
			logf("    second copy of every line permanently — and verification would then report a")
			logf("    mismatch that reads like corruption rather than a repeated run.")
			logf("    Set MIGRATE_FORCE=1 to proceed anyway.")
			return exitAlreadyMigrated, nil
		}
	} else {
		logf("==> no already-migrated guard set (MIGRATE_GUARD_QUERY empty): re-runs WILL duplicate lines")
	}

	// How many lines the source holds for this filter and window. Printed up front because it is the
	// number to compare the final total against — a transfer that moved fewer lines than the source holds
	// is the failure most likely to pass unnoticed.
	expected, err := countLogs(sourceURL, query, start, end)
	if err != nil {
		return 1, err
	}
	logf("==> source holds %d matching lines in this window", expected)
	if expected == 0 {
		logf("")
		logf("    Nothing to migrate. If that is unexpected, the filter is the first thing to check:")
		logf("    field names differ between log collectors, so a namespace may be recorded as")
		logf("    kubernetes.pod_namespace, kubernetes_namespace, namespace, or something else entirely.")
		logf("    `migrator fields` lists what this source actually has.")
		return 0, nil
	}

	streamFields, err := discoverStreamFields(sourceURL, start, end)
	if err != nil {
		return 1, err
	}
	logf("==> preserving log streams via _stream_fields=%s", streamFields)
	logf("")

	st := &migrationStats{}
	for cursor := start; cursor.Before(end); {
		windowEnd := cursor.Add(time.Duration(stepHours) * time.Hour)
		if windowEnd.After(end) {
			windowEnd = end
		}

		before := st.moved
		err := migrateAdaptive(
			sourceURL, targetURL, query, extraFields, streamFields,
			cursor, windowEnd, chunkLines, windowRetries, maxWindowLines, 0, st,
		)
		if err != nil {
			// Only a systemic abort reaches here. Report exactly where to resume, so a restarted run picks
			// up rather than beginning again.
			logf("")
			logf("==> ABORTED at %s after %d lines overall", rfc(cursor), st.moved)
			logf("    Resume with MIGRATE_START=%s (keeping MIGRATE_END=%s).", rfc(cursor), rfc(end))
			logf("    Re-running a window re-sends any part of it already imported.")
			return 1, err
		}
		logf("    %s .. %s  ->  %d lines  (running total %d)",
			rfc(cursor), rfc(windowEnd), st.moved-before, st.moved)
		cursor = windowEnd
	}

	logf("")
	logf("==> transfer finished")
	logf("    source reported (windows attempted) : %d", st.expected)
	logf("    lines forwarded                     : %d", st.moved)

	if lost := st.lost(); lost > 0 {
		pct := float64(lost) / float64(max(1, st.expected)) * 100
		logf("    lines NOT transferred               : %d (%.4f%%)", lost, pct)
	} else {
		logf("    lines NOT transferred               : 0")
	}
	if st.shortWindows > 0 {
		logf("    truncated windows                   : %d", st.shortWindows)
	}
	if st.failedWindows > 0 {
		logf("    failed windows (skipped)            : %d", st.failedWindows)
	}
	if st.unsplittable > 0 {
		logf("    windows too dense to split          : %d", st.unsplittable)
	}
	if len(st.examples) > 0 {
		logf("")
		logf("    representative problems:")
		for _, e := range st.examples {
			logf("      - %s", e)
		}
	}

	// The up-front count covered the whole range; this compares it against what was moved, which catches
	// anything the per-window accounting missed (e.g. windows skipped before their count succeeded).
	if st.moved != expected {
		logf("")
		logf("    NOTE: the up-front count for the whole range was %d, %d were forwarded.", expected, st.moved)
		logf("    A small gap is normal if the source is still receiving logs in this range.")
	}

	forceFlush(targetURL)
	logf("")
	logf("==> log migration complete: %d lines forwarded", st.moved)
	return 0, nil
}

// rfc formats a window boundary for the VictoriaLogs and VictoriaMetrics query APIs.
//
// MILLISECOND PRECISION IS LOAD-BEARING, not decoration. It is what allows a window to be bisected below
// one second: at second precision a 500ms window formats with start == end, which matches nothing, so the
// adaptive splitting would silently stop working rather than fail. Both APIs accept RFC3339 with
// fractional seconds.
func rfc(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z") }

// discoverStreamFields returns the union of stream field names present on the source over the window.
func discoverStreamFields(sourceURL string, start, end time.Time) (string, error) {
	q := url.Values{}
	q.Set("query", "*")
	q.Set("start", rfc(start))
	q.Set("end", rfc(end))

	var payload struct {
		Values []struct {
			Value string `json:"value"`
		} `json:"values"`
	}
	if err := getJSON(sourceURL+"/select/logsql/stream_field_names?"+q.Encode(), &payload); err != nil {
		return "", fmt.Errorf("discovering stream fields: %w", err)
	}

	names := make([]string, 0, len(payload.Values))
	for _, v := range payload.Values {
		if v.Value != "" {
			names = append(names, v.Value)
		}
	}
	if len(names) == 0 {
		return "", fmt.Errorf(
			"the source reports no stream fields at all over this window, which means it has no logs to\n" +
				"       migrate. Run `task seed` first, or widen MIGRATE_START/MIGRATE_END")
	}
	sort.Strings(names)
	return strings.Join(names, ","), nil
}

func countLogs(baseURL, query string, start, end time.Time) (int, error) {
	q := url.Values{}
	q.Set("query", query+" | stats count() n")
	q.Set("start", rfc(start))
	q.Set("end", rfc(end))

	count := 0
	err := eachLine(baseURL+"/select/logsql/query?"+q.Encode(), func(line []byte) error {
		var row struct {
			N json.Number `json:"n"`
		}
		if err := json.Unmarshal(line, &row); err != nil {
			return nil
		}
		if n, err := row.N.Int64(); err == nil {
			count = int(n)
		}
		return nil
	})
	if err != nil {
		return 0, fmt.Errorf("counting logs at %s: %w", baseURL, err)
	}
	return count, nil
}

// minWindow is the point below which a window is no longer bisected. A window this small holding more
// than maxLines is migrated anyway, with a warning.
//
// This was one minute until a real migration showed why that is too coarse: a burst on the busiest day
// put ~48,000 lines inside a single 42-second window, which could not be split and had to be exported
// oversized 606 times. Nothing truncated — 48k was still under the transport's limit — but the margin
// had been spent by an arbitrary floor rather than by anything physical.
//
// 100ms is possible only because timestamps are formatted with millisecond precision (see rfc). At
// second precision a sub-second window formats with start == end and matches nothing, so the floor and
// the timestamp format have to move together.
const minWindow = 100 * time.Millisecond

// maxConsecutiveFailures distinguishes occasional loss from systemic breakage.
//
// Losing the odd window is tolerable and expected on a long transfer through a tunnel. Losing this many
// in a row is not loss, it is something broken — a dead port-forward, expired credentials, a full disk —
// and continuing would spend hours producing nothing.
const maxConsecutiveFailures = 10

// migrationStats accumulates what actually happened, so the end of a long run can be honest about it.
type migrationStats struct {
	expected int // lines the source said it held, across all windows attempted
	moved    int // lines actually forwarded

	shortWindows  int // exports that returned fewer lines than the source reported (silent truncation)
	failedWindows int // windows that errored out even after retries
	unsplittable  int // windows too dense to bisect below minWindow

	consecutiveFailures int
	examples            []string // a few representative problems, for the summary
}

func (s *migrationStats) note(format string, args ...any) {
	if len(s.examples) < 10 {
		s.examples = append(s.examples, fmt.Sprintf(format, args...))
	}
}

func (s *migrationStats) lost() int {
	if s.expected <= s.moved {
		return 0
	}
	return s.expected - s.moved
}

// migrateAdaptive migrates a time range, bisecting it until each export is small enough to survive the
// transport, and checking every window against the source's own count.
//
// WHY THE BISECTION EXISTS — a measured failure, not caution. Exporting a large result set through a
// `kubectl port-forward` silently TRUNCATES: a window holding 346,365 lines returned only 70,748, and the
// same window truncated through curl too, so it is the tunnel rather than any one client. Go surfaces the
// cut as "chunked line ends with bare LF"; curl just stops early and says nothing, which is worse.
// Keeping each export well under that threshold avoids the problem rather than detecting it.
//
// WHY LOSS IS TOLERATED. Per-window counts are compared, but a shortfall is recorded and the run
// continues — occasional loss is acceptable here, and halting a multi-hour transfer over a few lines
// would be the wrong trade. What is NOT tolerated is loss going unreported: everything missed is counted
// and summarised at the end, so "we lost some" is a number rather than a feeling.
func migrateAdaptive(
	sourceURL, targetURL, query, extraFields, streamFields string,
	start, end time.Time, chunkLines, retries, maxLines, depth int, st *migrationStats,
) error {
	expected, err := countLogs(sourceURL, query, start, end)
	if err != nil {
		// A failed COUNT is different from a failed export: we do not know what we are missing, so this
		// window is recorded as failed and skipped.
		st.failedWindows++
		st.consecutiveFailures++
		st.note("count failed for %s .. %s: %v", rfc(start), rfc(end), err)
		logf("    count failed for %s .. %s: %v — skipping", rfc(start), rfc(end), err)
		if st.consecutiveFailures >= maxConsecutiveFailures {
			return fmt.Errorf("%d consecutive window failures — this is systemic, not occasional loss."+
				" Check `task vpn-status`/the port-forwards and credentials, then resume from %s",
				st.consecutiveFailures, rfc(start))
		}
		return nil
	}
	if expected == 0 {
		return nil
	}

	span := end.Sub(start)
	if expected > maxLines && span > minWindow {
		// Bisect on TIME rather than line count: the source is ordered by time, so halving the range is
		// the only split needing no state on either side.
		mid := start.Add(span / 2)
		logf("    %s%s .. %s holds %d lines (> %d) — splitting",
			strings.Repeat("  ", depth), rfc(start), rfc(end), expected, maxLines)

		if err := migrateAdaptive(sourceURL, targetURL, query, extraFields, streamFields,
			start, mid, chunkLines, retries, maxLines, depth+1, st); err != nil {
			return err
		}
		return migrateAdaptive(sourceURL, targetURL, query, extraFields, streamFields,
			mid, end, chunkLines, retries, maxLines, depth+1, st)
	}

	if expected > maxLines {
		st.unsplittable++
		logf("    WARNING: %s .. %s holds %d lines in under %s — cannot split further, exporting anyway"+
			" (may truncate)", rfc(start), rfc(end), expected, minWindow)
	}

	st.expected += expected

	moved, err := migrateWindowWithRetries(sourceURL, targetURL, query, extraFields, streamFields,
		start, end, chunkLines, retries)
	st.moved += moved

	if err != nil {
		st.failedWindows++
		st.consecutiveFailures++
		st.note("window %s .. %s failed after retries (%d/%d lines): %v",
			rfc(start), rfc(end), moved, expected, err)
		logf("    window %s .. %s FAILED after retries — moved %d of %d, continuing",
			rfc(start), rfc(end), moved, expected)
		if st.consecutiveFailures >= maxConsecutiveFailures {
			return fmt.Errorf("%d consecutive window failures — this is systemic, not occasional loss."+
				" Check the port-forwards and credentials, then resume from %s",
				st.consecutiveFailures, rfc(start))
		}
		return nil
	}

	st.consecutiveFailures = 0

	if moved != expected {
		// The export was cut mid-stream. Tolerated, but never silent.
		st.shortWindows++
		st.note("window %s .. %s truncated: %d of %d lines", rfc(start), rfc(end), moved, expected)
		logf("    window %s .. %s TRUNCATED: %d of %d lines (%d lost), continuing",
			rfc(start), rfc(end), moved, expected, expected-moved)
	}

	return nil
}

// migrateWindowWithRetries retries a window on failure.
//
// Each attempt re-sends the WHOLE window, so a retry duplicates whatever the failed attempt had already
// imported. That is the right trade only when duplicates are acceptable, which is why retries default to
// zero and the duplication is stated out loud rather than buried.
func migrateWindowWithRetries(
	sourceURL, targetURL, query, extraFields, streamFields string,
	start, end time.Time, chunkLines, retries int,
) (int, error) {
	var lastErr error
	for attempt := 0; attempt <= retries; attempt++ {
		if attempt > 0 {
			logf("    retry %d/%d for %s .. %s (re-sends the whole window; partial imports duplicate)",
				attempt, retries, rfc(start), rfc(end))
			time.Sleep(10 * time.Second)
		}
		moved, err := migrateWindow(sourceURL, targetURL, query, extraFields, streamFields, start, end, chunkLines)
		if err == nil {
			return moved, nil
		}
		lastErr = err
		logf("    window %s .. %s failed: %v", rfc(start), rfc(end), err)
	}
	return 0, lastErr
}

// migrateWindow streams one time window from source to target, returning the number of lines forwarded.
func migrateWindow(
	sourceURL, targetURL, query, extraFields, streamFields string,
	start, end time.Time, chunkLines int,
) (int, error) {
	exportQuery := url.Values{}
	exportQuery.Set("query", query)
	exportQuery.Set("start", rfc(start))
	exportQuery.Set("end", rfc(end))

	importQuery := url.Values{}
	importQuery.Set("_time_field", "_time")
	importQuery.Set("_msg_field", "_msg")
	importQuery.Set("_stream_fields", streamFields)
	// Derived fields the export includes but the target must not store: _stream is a rendered string,
	// _stream_id belongs to the source's storage.
	importQuery.Set("ignore_fields", "_stream,_stream_id")
	if extraFields != "" {
		// Stamped onto every entry by the server, so no line has to be parsed and rewritten client-side.
		importQuery.Set("extra_fields", extraFields)
	}

	importURL := targetURL + "/insert/jsonline?" + importQuery.Encode()

	forwarded := 0
	buffered := 0
	var batch strings.Builder

	flush := func() error {
		if buffered == 0 {
			return nil
		}
		// Compressed: these batches are the bulk of the transfer, and Kubernetes log lines repeat so much
		// pod metadata that gzip removes roughly 29/30ths of the bytes.
		if err := postGzip(importURL, []byte(batch.String()), "application/stream+json"); err != nil {
			return fmt.Errorf("importing into the target: %w", err)
		}
		forwarded += buffered
		buffered = 0
		batch.Reset()
		return nil
	}

	err := eachLine(sourceURL+"/select/logsql/query?"+exportQuery.Encode(), func(line []byte) error {
		// The scanner reuses its buffer, so the bytes are copied into the batch immediately rather than
		// retained.
		batch.Write(line)
		batch.WriteByte('\n')
		buffered++
		if buffered >= chunkLines {
			return flush()
		}
		return nil
	})
	if err != nil {
		return forwarded, fmt.Errorf("exporting from the source: %w", err)
	}
	if err := flush(); err != nil {
		return forwarded, err
	}
	return forwarded, nil
}
