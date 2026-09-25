package main

import (
	"strings"
	"testing"
	"time"
)

// These tests cover the parts of the CLI that can be wrong without AWS telling you: the two wire
// formats and the SQL templates. Everything else is an API call.

func TestMarshalCSVRoundTrip(t *testing.T) {
	t.Parallel()

	events := GenerateEvents(5)

	body, err := MarshalCSV(events)
	if err != nil {
		t.Fatalf("MarshalCSV: %v", err)
	}

	// The header must be present and in this order — the batch COPY maps CSV fields by position.
	firstLine := strings.SplitN(string(body), "\n", 2)[0]
	if got, want := strings.TrimSpace(firstLine), "user_id,event,event_time"; got != want {
		t.Errorf("csv header = %q, want %q", got, want)
	}

	parsed, err := ParseCSV(body)
	if err != nil {
		t.Fatalf("ParseCSV: %v", err)
	}
	if len(parsed) != len(events) {
		t.Fatalf("parsed %d events, want %d", len(parsed), len(events))
	}
	for i := range events {
		if parsed[i] != events[i] {
			t.Errorf("event %d round-tripped to %+v, want %+v", i, parsed[i], events[i])
		}
	}
}

func TestParseCSVRejectsHeaderOnly(t *testing.T) {
	t.Parallel()

	if _, err := ParseCSV([]byte("user_id,event,event_time\n")); err == nil {
		t.Error("expected an error for a CSV with no data rows")
	}
}

// MarshalRecord must terminate every record with a newline. Firehose concatenates the raw bytes of
// buffered records, so without the delimiter the delivered object is one unsplittable run of JSON that
// neither Redshift nor ParseJSONLines can read.
func TestMarshalRecordIsNewlineTerminated(t *testing.T) {
	t.Parallel()

	record, err := MarshalRecord(GenerateEvents(1)[0])
	if err != nil {
		t.Fatalf("MarshalRecord: %v", err)
	}
	if !strings.HasSuffix(string(record), "\n") {
		t.Fatalf("record %q is not newline-terminated", record)
	}
	if strings.Count(string(record), "\n") != 1 {
		t.Errorf("record has %d newlines, want exactly 1", strings.Count(string(record), "\n"))
	}
}

// Concatenating records the way Firehose does must produce something ParseJSONLines can read back.
func TestConcatenatedRecordsParse(t *testing.T) {
	t.Parallel()

	events := GenerateEvents(4)

	var delivered []byte
	for _, e := range events {
		record, err := MarshalRecord(e)
		if err != nil {
			t.Fatalf("MarshalRecord: %v", err)
		}
		delivered = append(delivered, record...)
	}

	parsed, err := ParseJSONLines(delivered)
	if err != nil {
		t.Fatalf("ParseJSONLines: %v", err)
	}
	if len(parsed) != len(events) {
		t.Fatalf("parsed %d events, want %d", len(parsed), len(events))
	}
	for i := range events {
		if !parsed[i].EventTime.Equal(events[i].EventTime) {
			t.Errorf("event %d time = %v, want %v", i, parsed[i].EventTime, events[i].EventTime)
		}
		if parsed[i].UserID != events[i].UserID || parsed[i].Event != events[i].Event {
			t.Errorf("event %d = %+v, want %+v", i, parsed[i], events[i])
		}
	}
}

func TestParseJSONLinesRejectsEmpty(t *testing.T) {
	t.Parallel()

	if _, err := ParseJSONLines([]byte("\n  \n")); err == nil {
		t.Error("expected an error for an object with no records")
	}
}

func TestMaxEventTime(t *testing.T) {
	t.Parallel()

	base := time.Date(2026, 9, 25, 10, 0, 0, 0, time.UTC)
	events := []Event{
		{EventTime: base.Add(1 * time.Minute)},
		{EventTime: base.Add(5 * time.Minute)},
		{EventTime: base},
	}

	got, ok := MaxEventTime(events)
	if !ok {
		t.Fatal("MaxEventTime reported no events")
	}
	if want := base.Add(5 * time.Minute); !got.Equal(want) {
		t.Errorf("MaxEventTime = %v, want %v", got, want)
	}

	if _, ok := MaxEventTime(nil); ok {
		t.Error("MaxEventTime on an empty slice should report false")
	}
}

// The SQL templates are embedded, so a rename or a typo in a placeholder is a silent failure until a
// real COPY runs. Render them and check the substitutions landed.
func TestRenderSQLTemplates(t *testing.T) {
	t.Parallel()

	params := sqlParams{
		Table:       "user_events_stream",
		BatchTable:  "user_events_batch",
		StreamTable: "user_events_stream",
		Bucket:      "example-bucket",
		Prefix:      "stream/",
		Region:      "us-east-1",
	}

	cases := []struct {
		template string
		contains []string
	}{
		{"create_table.sql.tmpl", []string{"CREATE TABLE IF NOT EXISTS user_events_stream", "event_time TIMESTAMP"}},
		{"truncate.sql.tmpl", []string{"TRUNCATE TABLE user_events_stream"}},
		{"count.sql.tmpl", []string{"FROM user_events_stream"}},
		{"sample.sql.tmpl", []string{"FROM user_events_stream", "LIMIT 10"}},
		{"copy_batch.sql.tmpl", []string{
			"COPY user_events_stream (user_id, event, event_time)",
			"'s3://example-bucket/stream/'",
			"IAM_ROLE default",
			"FORMAT AS CSV",
			"IGNOREHEADER 1",
			"REGION 'us-east-1'",
		}},
		{"copy_stream.sql.tmpl", []string{
			"COPY user_events_stream",
			"'s3://example-bucket/stream/'",
			"IAM_ROLE default",
			"FORMAT AS JSON 'auto'",
		}},
		{"view_unified_events.sql.tmpl", []string{
			"CREATE OR REPLACE VIEW v_unified_events",
			"FROM user_events_batch",
			"FROM user_events_stream",
		}},
		{"view_pipeline_event_summary.sql.tmpl", []string{
			"CREATE OR REPLACE VIEW v_pipeline_event_summary",
			"FROM v_unified_events",
		}},
		{"view_user_engagement_profile.sql.tmpl", []string{
			"CREATE OR REPLACE VIEW v_user_engagement_profile",
			"FROM v_unified_events",
		}},
	}

	for _, tc := range cases {
		t.Run(tc.template, func(t *testing.T) {
			t.Parallel()

			rendered, err := renderSQL(tc.template, params)
			if err != nil {
				t.Fatalf("renderSQL: %v", err)
			}
			for _, want := range tc.contains {
				if !strings.Contains(rendered, want) {
					t.Errorf("rendered SQL missing %q:\n%s", want, rendered)
				}
			}
			// An unresolved placeholder means a field was renamed on one side only.
			if strings.Contains(rendered, "{{") {
				t.Errorf("rendered SQL still contains a template action:\n%s", rendered)
			}
		})
	}
}

// LoadConfig must fail loudly without a bucket rather than proceeding against an empty bucket name.
func TestLoadConfigRequiresDataBucket(t *testing.T) {
	t.Setenv("DATA_BUCKET", "")

	if _, err := LoadConfig(); err == nil {
		t.Error("expected LoadConfig to fail when DATA_BUCKET is unset")
	}
}

func TestLoadConfigDefaults(t *testing.T) {
	t.Setenv("DATA_BUCKET", "example-bucket")
	t.Setenv("AWS_REGION", "")
	t.Setenv("STREAM_NAME", "")
	t.Setenv("REDSHIFT_WORKGROUP", "")

	cfg, err := LoadConfig()
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}

	// The defaults must match the names the Terragrunt units create, or the CLI silently points at
	// infrastructure that does not exist.
	if cfg.Region != "us-east-1" {
		t.Errorf("Region = %q, want us-east-1", cfg.Region)
	}
	if cfg.StreamName != "user-events" {
		t.Errorf("StreamName = %q, want user-events", cfg.StreamName)
	}
	if cfg.Workgroup != "events-warehouse" {
		t.Errorf("Workgroup = %q, want events-warehouse", cfg.Workgroup)
	}
	if cfg.BatchPrefix != "batch/" || cfg.StreamPrefix != "stream/" {
		t.Errorf("prefixes = %q/%q, want batch//stream/", cfg.BatchPrefix, cfg.StreamPrefix)
	}
}
