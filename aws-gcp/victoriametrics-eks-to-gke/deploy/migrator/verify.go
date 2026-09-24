package main

// `migrator verify` diffs the two databases and publishes the findings as metrics.
//
// WHAT "VERIFIED" MEANS HERE
//
// The gate is an EXACT diff of the seed dataset over its ENTIRE history: every series, every timestamp,
// every value for metrics; every line for logs. Not a count, not a sample, no tolerance. If one sample
// landed with a shifted timestamp or a rounded value, this fails.
//
// That is only a sound gate because of how the seed dataset is built (see seed.go): it is written once with
// backdated timestamps and never appended to, so it is IMMUTABLE. A full-history comparison of immutable
// data gives the same answer whether you run it a minute or a week after the migration — there is no race
// against the clock, which is what would otherwise force the comparison to be clipped to some safe window.
//
// WHY THE LIVE DATA IS CHECKED SEPARATELY, AND ONLY INFORMATIONALLY
//
// The source is still being scraped while the migration runs. Samples can be written to the source with
// timestamps just before the cutoff yet only become visible after the migration has already read that
// window. Demanding exact equality there would produce failures caused by physics rather than by a broken
// migration. So the live half is reported with a tolerance and never fails the gate. The seed dataset is
// what the gate rests on, and it is the stricter test of the two.
//
// Live data is identifiable at all because each cluster's vmagent stamps its scrapes with
// cluster="vmmig-source" / cluster="vmmig-target". Both clusters run a kube-state-metrics emitting
// identically named series, so without that label "which of these did we migrate?" has no answer.
//
// PUBLISHING THE RESULT
//
// Findings are pushed into the target VictoriaMetrics as migration_verify_* gauges. The Grafana dashboard
// then reads plain PromQL instead of reimplementing this comparison in dashboard queries, where it would be
// unreadable and easy to get subtly wrong. It also means every verification run is kept, so the verdict has
// a history.
//
// Environment:
//
//	SOURCE_VM_URL / TARGET_VM_URL   VictoriaMetrics base URLs (source reached over the VPN)
//	SOURCE_VL_URL / TARGET_VL_URL   VictoriaLogs base URLs
//	MIGRATE_START                   RFC3339 start of the migrated window
//	MIGRATE_CUTOFF                  RFC3339 migration cutoff (end of what was migrated)
//	PUSH_URL                        optional; where to push results (default: the target import API)

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"
)

const (
	seedMatch = `{__name__="lab_migration_sample",dataset="seed"}`
	liveMatch = `{cluster="vmmig-source",__name__!~"vm_.*|vmctl_.*|migration_verify_.*"}`

	// How far the live (non-gating) comparison may differ before it is called out. Scrapes in flight at
	// the cutoff make small differences expected rather than suspicious.
	liveTolerance = 0.01

	// Examples printed per failing category: enough to diagnose, not enough to bury the summary.
	maxExamples = 5
)

// sample is one point of one series. Comparable, so it works as a map key for multiset counting.
//
// Values stay float64 throughout: JSON numbers decode to float64 on both sides, so there is no
// int-versus-float mismatch to normalise away, and the seed's small integers are exactly representable —
// which is what makes demanding exact equality reasonable rather than brittle.
type sample struct {
	ts  int64
	val float64
}

// fingerprint identifies one seeded log line. `seq` is unique per line and `_time` catches a shifted
// timestamp, so the pair is a complete identity for this dataset.
type fingerprint struct {
	ts  int64
	seq string
}

type metricsReport struct {
	sourceSeries, targetSeries   int
	sourceSamples, targetSamples int
	sampleDiff                   int
	onlySource, onlyTarget       []string
	examples                     []string
	sourceOldest, sourceNewest   int64
	targetOldest, targetNewest   int64
	ok                           bool
}

type logsReport struct {
	sourceLines, targetLines int
	diff                     int
	examples                 []string
	ok                       bool
}

func runVerify() (int, error) {
	get := func(key string) (string, error) {
		v, err := mustEnv(key)
		return strings.TrimRight(v, "/"), err
	}

	sourceVM, err := get("SOURCE_VM_URL")
	if err != nil {
		return 1, err
	}
	targetVM, err := get("TARGET_VM_URL")
	if err != nil {
		return 1, err
	}
	sourceVL, err := get("SOURCE_VL_URL")
	if err != nil {
		return 1, err
	}
	targetVL, err := get("TARGET_VL_URL")
	if err != nil {
		return 1, err
	}
	registerRemote(sourceVM)
	registerRemote(sourceVL)

	startRaw, err := mustEnv("MIGRATE_START")
	if err != nil {
		return 1, err
	}
	cutoffRaw, err := mustEnv("MIGRATE_CUTOFF")
	if err != nil {
		return 1, err
	}
	// Parsed to validate the window even though the queries below pass the raw strings through:
	// VictoriaMetrics and VictoriaLogs both accept RFC3339 directly, and reformatting would only add a
	// place for the two sides' bounds to drift apart.
	start, err := time.Parse(time.RFC3339, startRaw)
	if err != nil {
		return 1, fmt.Errorf("MIGRATE_START %q is not RFC3339: %w", startRaw, err)
	}
	cutoff, err := time.Parse(time.RFC3339, cutoffRaw)
	if err != nil {
		return 1, fmt.Errorf("MIGRATE_CUTOFF %q is not RFC3339: %w", cutoffRaw, err)
	}
	if !start.Before(cutoff) {
		return 1, fmt.Errorf("MIGRATE_START (%s) must be before MIGRATE_CUTOFF (%s)", startRaw, cutoffRaw)
	}

	pushURL := os.Getenv("PUSH_URL")
	if pushURL == "" {
		pushURL = targetVM + "/api/v1/import/prometheus"
	}

	logf("==> migrated window : %s .. %s", startRaw, cutoffRaw)
	logf("==> source VM       : %s (over the VPN)", sourceVM)
	logf("==> target VM       : %s", targetVM)
	logf("")

	// --- The gate: seed metrics, full history, exact ---
	logf("==> comparing seed METRICS across their full history (exact: every timestamp, every value)")
	seedSrc, err := exportSeries(sourceVM, seedMatch, startRaw, cutoffRaw)
	if err != nil {
		return 1, err
	}
	seedTgt, err := exportSeries(targetVM, seedMatch, startRaw, cutoffRaw)
	if err != nil {
		return 1, err
	}
	mr := diffMetrics(seedSrc, seedTgt)

	logf("    source : %d series, %d samples", mr.sourceSeries, mr.sourceSamples)
	logf("    target : %d series, %d samples", mr.targetSeries, mr.targetSamples)
	logf("    differing samples : %d", mr.sampleDiff)
	if len(mr.onlySource) > 0 {
		logf("    series missing on target : %d", len(mr.onlySource))
		for _, k := range truncate(mr.onlySource, maxExamples) {
			logf("      - %s", k)
		}
	}
	if len(mr.onlyTarget) > 0 {
		logf("    series unexpected on target : %d", len(mr.onlyTarget))
		for _, k := range truncate(mr.onlyTarget, maxExamples) {
			logf("      + %s", k)
		}
	}
	for _, e := range mr.examples {
		logf("      ! %s", e)
	}
	logf("")

	// --- The gate: seed logs, full history, exact ---
	logf("==> comparing seed LOGS across their full history (exact: every line, by timestamp and seq)")
	logsSrc, err := logFingerprints(sourceVL, startRaw, cutoffRaw)
	if err != nil {
		return 1, err
	}
	logsTgt, err := logFingerprints(targetVL, startRaw, cutoffRaw)
	if err != nil {
		return 1, err
	}
	lr := diffLogs(logsSrc, logsTgt)

	logf("    source : %d lines", lr.sourceLines)
	logf("    target : %d lines", lr.targetLines)
	logf("    differing lines : %d", lr.diff)
	for _, e := range lr.examples {
		logf("      ! %s", e)
	}
	logf("")

	// --- Informational: the live, still-growing half ---
	logf("==> comparing LIVE scraped data up to the cutoff (informational — see the file header)")
	liveSrc, err := exportSeries(sourceVM, liveMatch, startRaw, cutoffRaw)
	if err != nil {
		return 1, err
	}
	liveTgt, err := exportSeries(targetVM, liveMatch, startRaw, cutoffRaw)
	if err != nil {
		return 1, err
	}
	liveSrcSamples := countSamples(liveSrc)
	liveTgtSamples := countSamples(liveTgt)
	delta := liveSrcSamples - liveTgtSamples
	if delta < 0 {
		delta = -delta
	}
	budget := int(float64(liveSrcSamples) * liveTolerance)
	if budget < 1 {
		budget = 1
	}
	liveOK := delta <= budget

	logf("    source : %d series, %d samples", len(liveSrc), liveSrcSamples)
	logf("    target : %d series, %d samples (labelled cluster=vmmig-source)", len(liveTgt), liveTgtSamples)
	logf("    delta  : %d (tolerance %d)", delta, budget)
	if !liveOK {
		logf("    NOTE: outside tolerance. Scrapes in flight at the cutoff explain a small gap; a large")
		logf("          one usually means the migration ran before the cutoff it was given.")
	}
	logf("")

	// --- Publish ---
	overallOK := mr.ok && lr.ok
	if err := publish(pushURL, mr, lr, liveSrcSamples, liveTgtSamples, liveOK, overallOK); err != nil {
		return 1, err
	}
	logf("==> results pushed to %s (the dashboard reads these)", pushURL)
	logf("")

	// --- Verdict ---
	bar := strings.Repeat("=", 78)
	logf("%s", bar)
	if overallOK {
		logf("  VERIFIED — the seed dataset is present on the target, sample for sample and line for")
		logf("  line, across its entire history, at its ORIGINAL timestamps.")
	} else {
		logf("  MISMATCH — the seed dataset is NOT identical on the two sides. Details above.")
		if mr.sourceSamples == 0 {
			logf("  The source holds no seed metrics at all: run `task seed` before migrating.")
		}
		if lr.sourceLines == 0 {
			logf("  The source holds no seed logs at all: run `task seed` before migrating.")
		}
	}
	logf("%s", bar)

	if overallOK {
		return 0, nil
	}
	return 1, nil
}

// exportSeries exports raw samples and folds them into series -> multiset of samples.
//
// /api/v1/export can emit SEVERAL lines for one series (one per storage block), so results are accumulated
// per series rather than assigned.
func exportSeries(baseURL, match, start, end string) (map[string]map[sample]int, error) {
	q := url.Values{}
	q.Set("match[]", match)
	q.Set("start", start)
	q.Set("end", end)

	out := map[string]map[sample]int{}
	err := eachLine(baseURL+"/api/v1/export?"+q.Encode(), func(line []byte) error {
		var row struct {
			Metric     map[string]string `json:"metric"`
			Values     []float64         `json:"values"`
			Timestamps []int64           `json:"timestamps"`
		}
		if err := json.Unmarshal(line, &row); err != nil {
			return nil // a line we cannot parse contributes nothing
		}
		key := seriesKey(row.Metric)
		if out[key] == nil {
			out[key] = map[sample]int{}
		}
		n := min(len(row.Values), len(row.Timestamps))
		for i := 0; i < n; i++ {
			out[key][sample{ts: row.Timestamps[i], val: row.Values[i]}]++
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("exporting %s from %s: %w", match, baseURL, err)
	}
	return out, nil
}

// seriesKey is a canonical, order-independent identity for a series.
func seriesKey(labels map[string]string) string {
	name := labels["__name__"]
	pairs := make([]string, 0, len(labels))
	for k, v := range labels {
		if k == "__name__" {
			continue
		}
		pairs = append(pairs, k+"="+v)
	}
	sort.Strings(pairs)
	return name + "{" + strings.Join(pairs, ",") + "}"
}

func countSamples(data map[string]map[sample]int) int {
	total := 0
	for _, counter := range data {
		for _, n := range counter {
			total += n
		}
	}
	return total
}

func diffMetrics(source, target map[string]map[sample]int) metricsReport {
	r := metricsReport{
		sourceSeries:  len(source),
		targetSeries:  len(target),
		sourceSamples: countSamples(source),
		targetSamples: countSamples(target),
	}

	keys := map[string]struct{}{}
	for k := range source {
		keys[k] = struct{}{}
	}
	for k := range target {
		keys[k] = struct{}{}
	}
	ordered := make([]string, 0, len(keys))
	for k := range keys {
		ordered = append(ordered, k)
	}
	sort.Strings(ordered)

	for _, key := range ordered {
		src, inSrc := source[key]
		tgt, inTgt := target[key]
		if !inTgt {
			r.onlySource = append(r.onlySource, key)
		}
		if !inSrc {
			r.onlyTarget = append(r.onlyTarget, key)
		}

		missing, extra, missingEx, extraEx := multisetDiff(src, tgt, 1)
		r.sampleDiff += missing + extra
		if len(r.examples) < maxExamples {
			switch {
			case len(missingEx) > 0:
				r.examples = append(r.examples, fmt.Sprintf("%s missing on target at ts=%d value=%v",
					key, missingEx[0].ts, missingEx[0].val))
			case len(extraEx) > 0:
				r.examples = append(r.examples, fmt.Sprintf("%s unexpected on target at ts=%d value=%v",
					key, extraEx[0].ts, extraEx[0].val))
			}
		}
	}

	r.sourceOldest, r.sourceNewest = timeBounds(source)
	r.targetOldest, r.targetNewest = timeBounds(target)
	r.ok = r.sampleDiff == 0 && len(r.onlySource) == 0 && len(r.onlyTarget) == 0 && r.sourceSamples > 0
	return r
}

// timeBounds returns the oldest and newest sample timestamps, in whole seconds.
func timeBounds(data map[string]map[sample]int) (oldest, newest int64) {
	first := true
	for _, counter := range data {
		for s := range counter {
			if first {
				oldest, newest, first = s.ts, s.ts, false
				continue
			}
			if s.ts < oldest {
				oldest = s.ts
			}
			if s.ts > newest {
				newest = s.ts
			}
		}
	}
	if first {
		return 0, 0
	}
	return oldest / 1000, newest / 1000
}

// logFingerprints fingerprints every seeded log line on one side.
//
// The `fields` pipe keeps the transfer to two columns instead of every field on every line.
func logFingerprints(baseURL, start, end string) (map[fingerprint]int, error) {
	q := url.Values{}
	q.Set("query", "dataset:"+datasetName+" | fields _time, seq")
	q.Set("start", start)
	q.Set("end", end)

	out := map[fingerprint]int{}
	err := eachLine(baseURL+"/select/logsql/query?"+q.Encode(), func(line []byte) error {
		var row struct {
			Time string `json:"_time"`
			Seq  string `json:"seq"`
		}
		if err := json.Unmarshal(line, &row); err != nil {
			return nil
		}
		if row.Time == "" || row.Seq == "" {
			return nil
		}
		// Normalise the timestamp to whole seconds: the two stores may render RFC3339 with different
		// sub-second precision, and that is a formatting difference, not a data difference.
		parsed, err := time.Parse(time.RFC3339, row.Time)
		if err != nil {
			return nil
		}
		out[fingerprint{ts: parsed.UTC().Unix(), seq: row.Seq}]++
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("reading seed logs from %s: %w", baseURL, err)
	}
	return out, nil
}

func diffLogs(source, target map[fingerprint]int) logsReport {
	missing, extra, missingEx, extraEx := multisetDiff(source, target, maxExamples)

	r := logsReport{diff: missing + extra}
	for _, n := range source {
		r.sourceLines += n
	}
	for _, n := range target {
		r.targetLines += n
	}
	for _, f := range missingEx {
		r.examples = append(r.examples, fmt.Sprintf("missing on target: seq=%s ts=%d", f.seq, f.ts))
	}
	for _, f := range truncate(extraEx, maxExamples-len(r.examples)) {
		r.examples = append(r.examples, fmt.Sprintf("unexpected on target: seq=%s ts=%d", f.seq, f.ts))
	}
	r.ok = r.diff == 0 && r.sourceLines > 0
	return r
}

func publish(pushURL string, mr metricsReport, lr logsReport, liveSrc, liveTgt int, liveOK, overallOK bool) error {
	b := func(v bool) int {
		if v {
			return 1
		}
		return 0
	}

	lines := []string{
		fmt.Sprintf("migration_verify_ok %d", b(overallOK)),
		fmt.Sprintf("migration_verify_metrics_ok %d", b(mr.ok)),
		fmt.Sprintf("migration_verify_logs_ok %d", b(lr.ok)),
		fmt.Sprintf(`migration_verify_samples{side="source"} %d`, mr.sourceSamples),
		fmt.Sprintf(`migration_verify_samples{side="target"} %d`, mr.targetSamples),
		fmt.Sprintf(`migration_verify_series{side="source"} %d`, mr.sourceSeries),
		fmt.Sprintf(`migration_verify_series{side="target"} %d`, mr.targetSeries),
		fmt.Sprintf("migration_verify_sample_diff %d", mr.sampleDiff),
		fmt.Sprintf(`migration_verify_log_lines{side="source"} %d`, lr.sourceLines),
		fmt.Sprintf(`migration_verify_log_lines{side="target"} %d`, lr.targetLines),
		fmt.Sprintf("migration_verify_log_diff %d", lr.diff),
		fmt.Sprintf(`migration_verify_oldest_sample_timestamp{side="source"} %d`, mr.sourceOldest),
		fmt.Sprintf(`migration_verify_oldest_sample_timestamp{side="target"} %d`, mr.targetOldest),
		fmt.Sprintf(`migration_verify_newest_sample_timestamp{side="source"} %d`, mr.sourceNewest),
		fmt.Sprintf(`migration_verify_newest_sample_timestamp{side="target"} %d`, mr.targetNewest),
		fmt.Sprintf(`migration_verify_live_samples{side="source"} %d`, liveSrc),
		fmt.Sprintf(`migration_verify_live_samples{side="target"} %d`, liveTgt),
		fmt.Sprintf("migration_verify_live_ok %d", b(liveOK)),
		fmt.Sprintf("migration_verify_run_timestamp %d", time.Now().UTC().Unix()),
	}

	body := strings.Join(lines, "\n") + "\n"
	if err := post(pushURL, []byte(body), "text/plain"); err != nil {
		return fmt.Errorf("publishing results: %w", err)
	}
	return nil
}

func truncate[T any](in []T, n int) []T {
	if n < 0 {
		n = 0
	}
	if len(in) <= n {
		return in
	}
	return in[:n]
}
