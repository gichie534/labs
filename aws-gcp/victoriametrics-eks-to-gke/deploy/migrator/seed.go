package main

// `migrator seed` writes a deterministic, BACKDATED dataset into the source VictoriaMetrics and
// VictoriaLogs.
//
// Why backdate instead of letting the generators run? Two reasons.
//
//  1. Time. "Migrate a week of history" should not require waiting a week. Backdating produces a week of
//     history in a few seconds.
//  2. Verifiability. The generators produce data nobody can predict, so the only thing you could assert
//     about them is "roughly the same amount arrived". This dataset comes from a pure function of
//     (series index, sample index), so the exact value at every exact timestamp is known in advance.
//     That is what lets `migrator verify` diff the two databases sample by sample and mean it.
//
// The seed is also IMMUTABLE once written: it is never appended to. So a full-history comparison stays
// exact however long after the migration you run it, even though the live generators keep writing
// alongside it. That property is what makes "verify the whole time range" a sound gate rather than a race
// against the clock.
//
// Re-running is safe for metrics: both stores run with -dedup.minScrapeInterval=1ms, so identical
// (timestamp, value) pairs collapse. Logs do NOT deduplicate, so the log half refuses to run twice
// unless SEED_FORCE=1.
//
// Environment:
//
//	VM_WRITE_URL           source VictoriaMetrics base URL
//	VL_WRITE_URL           source VictoriaLogs base URL
//	SEED_DAYS              days of history to write backwards from the anchor (default 7)
//	SEED_STEP_SECONDS      seconds between metric samples (default 300)
//	SEED_SERIES            number of distinct metric series (default 12)
//	SEED_LOG_STEP_SECONDS  seconds between log lines (default 60)
//	SEED_FORCE             set to 1 to write logs even if a previous seed is detected

import (
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"time"
)

const (
	metricName  = "lab_migration_sample"
	datasetName = "seed"

	// Both stores are configured with 30d retention, and both DROP data older than retention at INGEST
	// time — silently, from the writer's point of view. Refusing here is far kinder than a seed that
	// reports success while having stored nothing.
	retentionDays = 30
)

var (
	seedRegions  = []string{"us-east", "eu-west", "ap-south"}
	seedTiers    = []string{"gold", "silver"}
	seedServices = []string{"checkout", "billing", "search"}
	seedLevels   = []string{"info", "warn", "error"}
)

// importSeries is one line of the /api/v1/import JSON-lines payload.
type importSeries struct {
	Metric     map[string]string `json:"metric"`
	Values     []int64           `json:"values"`
	Timestamps []int64           `json:"timestamps"`
}

// logEntry is one line of the /insert/jsonline ndjson payload. A struct rather than a map so the field
// order is fixed and the payload is byte-identical between runs.
type logEntry struct {
	Time    string `json:"_time"`
	Msg     string `json:"_msg"`
	Dataset string `json:"dataset"`
	Service string `json:"service"`
	Level   string `json:"level"`
	Seq     string `json:"seq"`
}

// sampleValue is the value at a given point.
//
// Integer-valued on purpose. Migration moves float64 values, and comparing floats for exact equality is
// a trap unless the values are exactly representable. Small integers always are, so `verify` can demand
// exact equality instead of picking an epsilon and hoping.
func sampleValue(seriesIndex, sampleIndex int) int64 {
	return int64(seriesIndex)*1_000_000 + int64(sampleIndex)
}

func runSeed() (int, error) {
	vmURL, err := mustEnv("VM_WRITE_URL")
	if err != nil {
		return 1, err
	}
	vlURL, err := mustEnv("VL_WRITE_URL")
	if err != nil {
		return 1, err
	}
	vmURL = strings.TrimRight(vmURL, "/")
	vlURL = strings.TrimRight(vlURL, "/")

	days, err := envInt("SEED_DAYS", 7)
	if err != nil {
		return 1, err
	}
	stepSeconds, err := envInt("SEED_STEP_SECONDS", 300)
	if err != nil {
		return 1, err
	}
	seriesCount, err := envInt("SEED_SERIES", 12)
	if err != nil {
		return 1, err
	}
	logStepSeconds, err := envInt("SEED_LOG_STEP_SECONDS", 60)
	if err != nil {
		return 1, err
	}

	if days < 1 {
		return 1, fmt.Errorf("SEED_DAYS must be at least 1, got %d", days)
	}
	if days >= retentionDays {
		return 1, fmt.Errorf(
			"SEED_DAYS=%d is not safely below the %dd retention configured on both stores.\n"+
				"       Backdated data older than retention is discarded at ingest, so the seed would appear to\n"+
				"       succeed while storing nothing. Lower SEED_DAYS or raise retentionPeriod in the values files",
			days, retentionDays)
	}

	// The anchor is the top of the current hour, NOT "now". An exact, reproducible boundary means a
	// re-run writes to the same timestamps (and therefore deduplicates) instead of laying down a second,
	// slightly-offset copy of the whole dataset.
	anchor := time.Now().UTC().Truncate(time.Hour)
	start := anchor.AddDate(0, 0, -days)

	logf("==> seed window: %s .. %s (%dd)", start.Format(time.RFC3339), anchor.Format(time.RFC3339), days)
	logf("==> metric step %ds, log step %ds", stepSeconds, logStepSeconds)

	samples, err := seedMetrics(vmURL, start, days, stepSeconds, seriesCount)
	if err != nil {
		return 1, err
	}

	lines, err := seedLogs(vlURL, start, days, logStepSeconds)
	if err != nil {
		return 1, err
	}

	logf("")
	logf("==> seed complete")
	logf("    metric samples : %d", samples)
	logf("    log lines      : %d", lines)
	logf("    window start   : %s", start.Format(time.RFC3339))
	logf("    window end     : %s", anchor.Format(time.RFC3339))
	return 0, nil
}

func seedMetrics(vmURL string, start time.Time, days, stepSeconds, seriesCount int) (int, error) {
	totalSamples := (days * 24 * 3600) / stepSeconds
	startMillis := start.UnixMilli()
	stepMillis := int64(stepSeconds) * 1000

	var payload strings.Builder
	written := 0

	for i := 0; i < seriesCount; i++ {
		row := importSeries{
			Metric: map[string]string{
				"__name__": metricName,
				"dataset":  datasetName,
				"series":   fmt.Sprintf("s%02d", i),
				"region":   seedRegions[i%len(seedRegions)],
				"tier":     seedTiers[i%len(seedTiers)],
			},
			Values:     make([]int64, 0, totalSamples),
			Timestamps: make([]int64, 0, totalSamples),
		}
		for n := 0; n < totalSamples; n++ {
			row.Timestamps = append(row.Timestamps, startMillis+int64(n)*stepMillis)
			row.Values = append(row.Values, sampleValue(i, n))
		}

		encoded, err := json.Marshal(row)
		if err != nil {
			return 0, fmt.Errorf("encoding series s%02d: %w", i, err)
		}
		payload.Write(encoded)
		payload.WriteByte('\n')
		written += len(row.Timestamps)
	}

	logf("==> writing %d samples across %d series to %s", written, seriesCount, vmURL)
	if err := post(vmURL+"/api/v1/import", []byte(payload.String()), "application/json"); err != nil {
		return 0, fmt.Errorf("importing metrics: %w", err)
	}

	logf("==> flushing pending writes so the data is immediately queryable")
	forceFlush(vmURL)
	return written, nil
}

// seedLogsPresent reports whether a previous seed already wrote logs.
//
// VictoriaLogs has neither deduplication nor delete-by-query, so a second unguarded run would leave two
// copies of every line with no way to remove one. Verification would then report the target holding half
// as many lines as the source, which reads like a broken migration rather than a double seed.
func seedLogsPresent(vlURL string) (bool, error) {
	q := url.Values{}
	q.Set("query", fmt.Sprintf("dataset:%s | stats count() n", datasetName))

	count := 0
	err := eachLine(vlURL+"/select/logsql/query?"+q.Encode(), func(line []byte) error {
		var row struct {
			N json.Number `json:"n"`
		}
		if err := json.Unmarshal(line, &row); err != nil {
			return nil // a line we cannot parse is not evidence of anything
		}
		if n, err := row.N.Int64(); err == nil && n > 0 {
			count = int(n)
		}
		return nil
	})
	if err != nil {
		return false, fmt.Errorf("checking for an existing seed: %w", err)
	}
	return count > 0, nil
}

func seedLogs(vlURL string, start time.Time, days, logStepSeconds int) (int, error) {
	present, err := seedLogsPresent(vlURL)
	if err != nil {
		return 0, err
	}
	if present && !envIs("SEED_FORCE", "1") {
		logf("==> SKIPPING logs: this dataset is already present in the source VictoriaLogs.")
		logf("    VictoriaLogs cannot deduplicate or delete, so writing again would create a second")
		logf("    copy of every line. Re-run with SEED_FORCE=1 only if you know the store is empty.")
		return 0, nil
	}

	total := (days * 24 * 3600) / logStepSeconds
	var payload strings.Builder

	for n := 0; n < total; n++ {
		ts := start.Add(time.Duration(n*logStepSeconds) * time.Second)
		service := seedServices[n%len(seedServices)]
		level := seedLevels[n%len(seedLevels)]

		entry := logEntry{
			// RFC3339 in explicit UTC. VictoriaLogs parses a timestamp WITHOUT a zone in the server's
			// local timezone, which would shift every line by the cluster's offset.
			Time:    ts.Format("2006-01-02T15:04:05Z"),
			Msg:     fmt.Sprintf("seed log line seq=%d service=%s level=%s", n, service, level),
			Dataset: datasetName,
			Service: service,
			Level:   level,
			Seq:     fmt.Sprintf("%d", n),
		}
		encoded, err := json.Marshal(entry)
		if err != nil {
			return 0, fmt.Errorf("encoding log line %d: %w", n, err)
		}
		payload.Write(encoded)
		payload.WriteByte('\n')
	}

	// _stream_fields declares which fields identify a log stream. Naming them explicitly keeps the seeded
	// streams stable and predictable ({service,dataset}), which in turn keeps the migration's stream
	// reconstruction verifiable.
	q := url.Values{}
	q.Set("_time_field", "_time")
	q.Set("_msg_field", "_msg")
	q.Set("_stream_fields", "service,dataset")

	logf("==> writing %d log lines to %s", total, vlURL)
	if err := post(vlURL+"/insert/jsonline?"+q.Encode(), []byte(payload.String()), "application/stream+json"); err != nil {
		return 0, fmt.Errorf("importing logs: %w", err)
	}
	forceFlush(vlURL)
	return total, nil
}
