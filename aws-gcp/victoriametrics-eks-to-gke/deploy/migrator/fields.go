package main

// `migrator fields` inspects a VictoriaLogs instance read-only and reports what is actually in it.
//
// It exists because the single most likely way to get a real log migration wrong is the FILTER. Log
// collectors disagree about field names: the same Kubernetes namespace may be recorded as
// `kubernetes.pod_namespace`, `kubernetes_namespace`, `namespace`, or something a custom pipeline
// invented. A filter naming the wrong field matches nothing, the migration reports success, and nothing
// moves — a failure that looks exactly like success.
//
// So this runs first, against the source, and answers three questions:
//
//	what fields exist, and which look like a namespace
//	which values does the candidate field actually take
//	how many lines match the filter you are about to use, over the window you are about to use
//
// Nothing here writes. It is safe against production.
//
// Environment:
//
//	VL_URL          the VictoriaLogs instance to inspect
//	FIELDS_START    RFC3339 start of the window to inspect (default: 30 days ago)
//	FIELDS_END      RFC3339 end of the window   (default: now)
//	FIELDS_FIELD    optional: list the VALUES of this field instead of just field names
//	FIELDS_QUERY    optional: count the lines matching this LogsQL filter (the dry run)

import (
	"fmt"
	"net/url"
	"os"
	"sort"
	"strings"
	"time"
)

// Hints that a field carries a Kubernetes namespace. Used only to draw the eye; the full field list is
// printed regardless.
//
// Kept narrow on purpose. An earlier version also matched the substring "ns", which flagged `build_options_ms`,
// `app_status_update_ms` and similar — and a hint that fires on a third of the fields is worse than no hint,
// because it trains you to ignore it.
var namespaceHints = []string{"namespace"}

// Field names that ARE a namespace despite not containing the word.
var namespaceExact = map[string]bool{"ns": true, "k8s_ns": true, "kubernetes_ns": true}

type valueCount struct {
	Value string `json:"value"`
	Hits  int    `json:"hits"`
}

type valuesResponse struct {
	Values []valueCount `json:"values"`
}

func runFields() (int, error) {
	vlURL, err := mustEnv("VL_URL")
	if err != nil {
		return 1, err
	}
	vlURL = strings.TrimRight(vlURL, "/")

	end := time.Now().UTC()
	if raw := os.Getenv("FIELDS_END"); raw != "" {
		end, err = time.Parse(time.RFC3339, raw)
		if err != nil {
			return 1, fmt.Errorf("FIELDS_END %q is not RFC3339: %w", raw, err)
		}
	}
	start := end.AddDate(0, 0, -30)
	if raw := os.Getenv("FIELDS_START"); raw != "" {
		start, err = time.Parse(time.RFC3339, raw)
		if err != nil {
			return 1, fmt.Errorf("FIELDS_START %q is not RFC3339: %w", raw, err)
		}
	}

	logf("==> inspecting %s", vlURL)
	logf("==> window     %s .. %s", rfc(start), rfc(end))
	logf("")

	if err := reportStreamFields(vlURL, start, end); err != nil {
		return 1, err
	}
	if err := reportAllFields(vlURL, start, end); err != nil {
		return 1, err
	}
	if field := os.Getenv("FIELDS_FIELD"); field != "" {
		if err := reportFieldValues(vlURL, field, start, end); err != nil {
			return 1, err
		}
	}
	if query := os.Getenv("FIELDS_QUERY"); query != "" {
		if err := reportQueryCount(vlURL, query, start, end); err != nil {
			return 1, err
		}
	}
	return 0, nil
}

func windowParams(start, end time.Time) url.Values {
	q := url.Values{}
	q.Set("start", rfc(start))
	q.Set("end", rfc(end))
	return q
}

// reportStreamFields lists the fields that identify log streams — the set the migration passes as
// _stream_fields, and therefore the set whose loss would silently re-group the target's logs.
func reportStreamFields(vlURL string, start, end time.Time) error {
	q := windowParams(start, end)
	q.Set("query", "*")

	var resp valuesResponse
	if err := getJSON(vlURL+"/select/logsql/stream_field_names?"+q.Encode(), &resp); err != nil {
		return fmt.Errorf("listing stream fields: %w", err)
	}

	logf("--- STREAM fields (these identify a log stream; the migration preserves exactly these) ---")
	if len(resp.Values) == 0 {
		logf("    none — this instance holds no logs in this window")
		return nil
	}
	sort.Slice(resp.Values, func(i, j int) bool { return resp.Values[i].Value < resp.Values[j].Value })
	for _, v := range resp.Values {
		logf("    %-40s %d hits%s", v.Value, v.Hits, hint(v.Value))
	}
	logf("")
	return nil
}

func reportAllFields(vlURL string, start, end time.Time) error {
	q := windowParams(start, end)
	q.Set("query", "*")

	var resp valuesResponse
	if err := getJSON(vlURL+"/select/logsql/field_names?"+q.Encode(), &resp); err != nil {
		return fmt.Errorf("listing field names: %w", err)
	}

	logf("--- ALL fields ---")
	sort.Slice(resp.Values, func(i, j int) bool { return resp.Values[i].Value < resp.Values[j].Value })
	for _, v := range resp.Values {
		logf("    %-40s %d hits%s", v.Value, v.Hits, hint(v.Value))
	}
	logf("")
	return nil
}

func reportFieldValues(vlURL, field string, start, end time.Time) error {
	q := windowParams(start, end)
	q.Set("query", "*")
	q.Set("field", field)
	q.Set("limit", "50")

	var resp valuesResponse
	if err := getJSON(vlURL+"/select/logsql/field_values?"+q.Encode(), &resp); err != nil {
		return fmt.Errorf("listing values of %q: %w", field, err)
	}

	logf("--- values of %q (top 50 by hits) ---", field)
	if len(resp.Values) == 0 {
		logf("    none — either the field does not exist or it is empty in this window")
	}
	for _, v := range resp.Values {
		logf("    %-40s %d hits", v.Value, v.Hits)
	}
	logf("")
	return nil
}

// reportQueryCount is the dry run: how many lines the filter you intend to migrate actually matches.
func reportQueryCount(vlURL, query string, start, end time.Time) error {
	n, err := countLogs(vlURL, query, start, end)
	if err != nil {
		return err
	}

	logf("--- DRY RUN ---")
	logf("    filter : %s", query)
	logf("    window : %s .. %s", rfc(start), rfc(end))
	logf("    matches: %d lines", n)
	if n == 0 {
		logf("")
		logf("    Zero matches. Check the filter against the field list above before migrating —")
		logf("    a filter naming a field that does not exist matches nothing and fails silently.")
	}
	logf("")
	return nil
}

func hint(field string) string {
	lower := strings.ToLower(field)
	if namespaceExact[lower] {
		return "   <-- looks like a namespace field"
	}
	for _, h := range namespaceHints {
		if strings.Contains(lower, h) {
			return "   <-- looks like a namespace field"
		}
	}
	return ""
}
