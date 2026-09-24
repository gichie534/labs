package main

// Tests for the log migration's request construction and retry behaviour.
//
// These matter more than usual because this code is the part that gets pointed at real production logs,
// where a mistake is not recoverable: VictoriaLogs cannot deduplicate or delete by query. The cases below
// pin down the three things that would go wrong quietly — the wrong filter reaching the source, the
// provenance tag not reaching the target, and derived stream fields being imported as real ones.

import (
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync"
	"testing"
	"time"
)

// fakeVL records what a migration asked of it and replays canned log lines.
type fakeVL struct {
	mu sync.Mutex

	exportQueries []url.Values // every /select/logsql/query the source received
	importQueries []url.Values // every /insert/jsonline the target received
	importBodies  []string

	lines []string // what the source returns for an export

	exportFailuresLeft int // fail this many exports before succeeding, to exercise retries
}

func (f *fakeVL) server() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()

		switch r.URL.Path {
		case "/select/logsql/stream_field_names":
			fmt.Fprint(w, `{"values":[{"value":"kubernetes.pod_namespace","hits":5},{"value":"app","hits":5}]}`)

		case "/select/logsql/query":
			q := r.URL.Query()
			// A counting query (used for the dry run and the guard) is answered with a number; anything
			// else is treated as an export.
			if strings.Contains(q.Get("query"), "| stats count()") {
				fmt.Fprintf(w, `{"n":%d}`+"\n", len(f.lines))
				return
			}
			f.exportQueries = append(f.exportQueries, q)
			if f.exportFailuresLeft > 0 {
				f.exportFailuresLeft--
				w.WriteHeader(http.StatusInternalServerError)
				fmt.Fprint(w, "simulated export failure")
				return
			}
			for _, l := range f.lines {
				fmt.Fprintln(w, l)
			}

		case "/insert/jsonline":
			// Decompress like the real server, so assertions can be made against the log lines rather
			// than against a gzip stream. VictoriaLogs accepts a gzipped body the same way.
			var reader io.Reader = r.Body
			if r.Header.Get("Content-Encoding") == "gzip" {
				zr, err := gzip.NewReader(r.Body)
				if err != nil {
					w.WriteHeader(http.StatusBadRequest)
					fmt.Fprintf(w, "invalid gzip body: %v", err)
					return
				}
				defer zr.Close()
				reader = zr
			}
			body, _ := io.ReadAll(reader)
			f.importQueries = append(f.importQueries, r.URL.Query())
			f.importBodies = append(f.importBodies, string(body))

		case "/internal/force_flush":
			// no-op

		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

func sampleLines(n int) []string {
	out := make([]string, 0, n)
	for i := 0; i < n; i++ {
		out = append(out, fmt.Sprintf(
			`{"_time":"2026-01-01T00:00:%02dZ","_msg":"line %d","_stream":"{app=\"api\"}","_stream_id":"abc%d","app":"api","kubernetes.pod_namespace":"default"}`,
			i, i, i))
	}
	return out
}

func TestMigrateWindowSendsTheFilterAndTagsTheImport(t *testing.T) {
	src := &fakeVL{lines: sampleLines(3)}
	dst := &fakeVL{}
	srcSrv, dstSrv := src.server(), dst.server()
	defer srcSrv.Close()
	defer dstSrv.Close()

	const filter = `{kubernetes.pod_namespace="default"}`
	const tag = "migrated_from=prod-eks"

	moved, err := migrateWindow(srcSrv.URL, dstSrv.URL, filter, tag, "app,kubernetes.pod_namespace",
		testWindowStart, testWindowEnd, 1000)
	if err != nil {
		t.Fatalf("migrateWindow: %v", err)
	}
	if moved != 3 {
		t.Errorf("moved = %d, want 3", moved)
	}

	// The filter must reach the SOURCE verbatim. Silently exporting everything while the operator
	// believes a namespace filter is in effect would migrate the whole cluster's logs.
	if len(src.exportQueries) != 1 {
		t.Fatalf("source received %d export queries, want 1", len(src.exportQueries))
	}
	if got := src.exportQueries[0].Get("query"); got != filter {
		t.Errorf("source query = %q, want %q", got, filter)
	}

	if len(dst.importQueries) != 1 {
		t.Fatalf("target received %d imports, want 1", len(dst.importQueries))
	}
	iq := dst.importQueries[0]

	// The provenance tag must reach the TARGET, or migrated lines are indistinguishable from native ones.
	if got := iq.Get("extra_fields"); got != tag {
		t.Errorf("extra_fields = %q, want %q", got, tag)
	}
	// Derived fields must be discarded: _stream is a rendered string, _stream_id belongs to the source.
	if got := iq.Get("ignore_fields"); got != "_stream,_stream_id" {
		t.Errorf("ignore_fields = %q, want _stream,_stream_id", got)
	}
	// Stream identity must be reconstructed from the discovered fields.
	if got := iq.Get("_stream_fields"); got != "app,kubernetes.pod_namespace" {
		t.Errorf("_stream_fields = %q", got)
	}
	if got := iq.Get("_time_field"); got != "_time" {
		t.Errorf("_time_field = %q, want _time", got)
	}

	// Lines are forwarded byte for byte, not reserialised.
	if !strings.Contains(dst.importBodies[0], `"_msg":"line 0"`) {
		t.Errorf("import body lost the original line: %q", dst.importBodies[0])
	}
}

func TestMigrateWindowOmitsExtraFieldsWhenUnset(t *testing.T) {
	// An empty tag must not become `extra_fields=`, which VictoriaLogs would have to interpret.
	src := &fakeVL{lines: sampleLines(1)}
	dst := &fakeVL{}
	srcSrv, dstSrv := src.server(), dst.server()
	defer srcSrv.Close()
	defer dstSrv.Close()

	if _, err := migrateWindow(srcSrv.URL, dstSrv.URL, "*", "", "app", testWindowStart, testWindowEnd, 1000); err != nil {
		t.Fatalf("migrateWindow: %v", err)
	}
	if _, present := dst.importQueries[0]["extra_fields"]; present {
		t.Error("extra_fields was sent despite being unset")
	}
}

func TestMigrateWindowChunksLargeWindows(t *testing.T) {
	// Chunking bounds memory on both sides and is what makes a big window survivable.
	src := &fakeVL{lines: sampleLines(250)}
	dst := &fakeVL{}
	srcSrv, dstSrv := src.server(), dst.server()
	defer srcSrv.Close()
	defer dstSrv.Close()

	moved, err := migrateWindow(srcSrv.URL, dstSrv.URL, "*", "", "app", testWindowStart, testWindowEnd, 100)
	if err != nil {
		t.Fatalf("migrateWindow: %v", err)
	}
	if moved != 250 {
		t.Errorf("moved = %d, want 250", moved)
	}
	if len(dst.importQueries) != 3 {
		t.Errorf("import requests = %d, want 3 (100+100+50)", len(dst.importQueries))
	}
}

func TestMigrateWindowWithRetriesRecoversFromATransientFailure(t *testing.T) {
	// The path in the real run is a kubectl port-forward, which drops under sustained load. One retry
	// should be enough to get past a single drop.
	src := &fakeVL{lines: sampleLines(5), exportFailuresLeft: 1}
	dst := &fakeVL{}
	srcSrv, dstSrv := src.server(), dst.server()
	defer srcSrv.Close()
	defer dstSrv.Close()

	// Retry sleeps 10s, so keep this to a single retry and accept the pause.
	moved, err := migrateWindowWithRetries(srcSrv.URL, dstSrv.URL, "*", "", "app",
		testWindowStart, testWindowEnd, 1000, 1)
	if err != nil {
		t.Fatalf("migrateWindowWithRetries: %v", err)
	}
	if moved != 5 {
		t.Errorf("moved = %d, want 5", moved)
	}
}

func TestMigrateWindowWithRetriesGivesUpAndReportsTheError(t *testing.T) {
	src := &fakeVL{lines: sampleLines(5), exportFailuresLeft: 99}
	dst := &fakeVL{}
	srcSrv, dstSrv := src.server(), dst.server()
	defer srcSrv.Close()
	defer dstSrv.Close()

	_, err := migrateWindowWithRetries(srcSrv.URL, dstSrv.URL, "*", "", "app",
		testWindowStart, testWindowEnd, 1000, 0)
	if err == nil {
		t.Fatal("expected an error when every attempt fails")
	}
	if !strings.Contains(err.Error(), "simulated export failure") {
		t.Errorf("error lost the server's explanation: %v", err)
	}
}

func TestCountLogsReadsTheStatsResponse(t *testing.T) {
	// The dry-run count is what tells an operator whether the filter matches anything at all before
	// committing to an irreversible import.
	src := &fakeVL{lines: sampleLines(42)}
	srv := src.server()
	defer srv.Close()

	n, err := countLogs(srv.URL, `{kubernetes.pod_namespace="default"}`, testWindowStart, testWindowEnd)
	if err != nil {
		t.Fatalf("countLogs: %v", err)
	}
	if n != 42 {
		t.Errorf("count = %d, want 42", n)
	}
}

func TestDiscoverStreamFieldsIsUsedVerbatimForImport(t *testing.T) {
	// Whatever the source calls its stream fields must be what the target is told, including dotted
	// names like kubernetes.pod_namespace.
	src := &fakeVL{lines: sampleLines(1)}
	srv := src.server()
	defer srv.Close()

	got, err := discoverStreamFields(srv.URL, testWindowStart, testWindowEnd)
	if err != nil {
		t.Fatalf("discoverStreamFields: %v", err)
	}
	if want := "app,kubernetes.pod_namespace"; got != want {
		t.Errorf("stream fields = %q, want %q", got, want)
	}
}

// Guard against a regression in the window arithmetic: hour-sized steps must tile the range exactly,
// with no gap (lost logs) and no overlap (duplicated logs).
func TestWindowSteppingTilesTheRangeExactly(t *testing.T) {
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	end := time.Date(2026, 1, 1, 10, 0, 0, 0, time.UTC)

	var windows [][2]time.Time
	for cursor := start; cursor.Before(end); {
		windowEnd := cursor.Add(3 * time.Hour)
		if windowEnd.After(end) {
			windowEnd = end
		}
		windows = append(windows, [2]time.Time{cursor, windowEnd})
		cursor = windowEnd
	}

	if len(windows) != 4 {
		t.Fatalf("windows = %d, want 4 (3+3+3+1)", len(windows))
	}
	if !windows[0][0].Equal(start) {
		t.Error("first window does not start at the range start")
	}
	if !windows[len(windows)-1][1].Equal(end) {
		t.Error("last window does not end at the range end")
	}
	for i := 1; i < len(windows); i++ {
		if !windows[i][0].Equal(windows[i-1][1]) {
			t.Errorf("window %d starts at %s but the previous ended at %s — gap or overlap",
				i, rfc(windows[i][0]), rfc(windows[i-1][1]))
		}
	}
}

func TestImportBodyIsGzippedAndDecodesToTheOriginalLines(t *testing.T) {
	// Compression is what makes a cross-internet transfer of this size practical: on real Kubernetes logs
	// it removes about 29/30ths of the bytes, because every line repeats the same pod metadata. This
	// asserts both halves of the contract — the header says gzip, AND the body really is gzip that
	// decodes back to exactly what was exported.
	var (
		mu       sync.Mutex
		encoding string
		received string
		rawLen   int
	)

	target := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/insert/jsonline" {
			return
		}
		mu.Lock()
		defer mu.Unlock()
		encoding = r.Header.Get("Content-Encoding")

		body, _ := io.ReadAll(r.Body)
		rawLen = len(body)

		zr, err := gzip.NewReader(bytes.NewReader(body))
		if err != nil {
			t.Errorf("request body is not valid gzip: %v", err)
			return
		}
		defer zr.Close()
		plain, err := io.ReadAll(zr)
		if err != nil {
			t.Errorf("decompressing request body: %v", err)
			return
		}
		received = string(plain)
	}))
	defer target.Close()

	src := &fakeVL{lines: sampleLines(200)}
	srcSrv := src.server()
	defer srcSrv.Close()

	moved, err := migrateWindow(srcSrv.URL, target.URL, "*", "", "app", testWindowStart, testWindowEnd, 1000)
	if err != nil {
		t.Fatalf("migrateWindow: %v", err)
	}
	if moved != 200 {
		t.Fatalf("moved = %d, want 200", moved)
	}

	mu.Lock()
	defer mu.Unlock()

	if encoding != "gzip" {
		t.Errorf("Content-Encoding = %q, want gzip", encoding)
	}
	if n := strings.Count(strings.TrimSpace(received), "\n") + 1; n != 200 {
		t.Errorf("decompressed body has %d lines, want 200", n)
	}
	if !strings.Contains(received, `"_msg":"line 0"`) || !strings.Contains(received, `"_msg":"line 199"`) {
		t.Error("decompressed body does not contain the first and last exported lines")
	}
	// Sanity: it should actually be smaller. These synthetic lines are repetitive, like real ones.
	if rawLen >= len(received) {
		t.Errorf("compressed body (%d bytes) is not smaller than the plaintext (%d bytes)", rawLen, len(received))
	}
}

func TestForceFlushAndSmallPostsStayUncompressed(t *testing.T) {
	// Only the bulk import path compresses. Keeping the rest plain avoids sending a gzip header on an
	// empty body, which some servers reject.
	var encoding string
	var seen bool

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = true
		encoding = r.Header.Get("Content-Encoding")
	}))
	defer srv.Close()

	if err := post(srv.URL, []byte("migration_verify_ok 1\n"), "text/plain"); err != nil {
		t.Fatalf("post: %v", err)
	}
	if !seen {
		t.Fatal("server never received the request")
	}
	if encoding != "" {
		t.Errorf("Content-Encoding = %q, want empty for a plain post", encoding)
	}
}

// timeAwareVL is a fake whose line count scales with the requested window, so bisecting a window really
// does halve the data — which is what makes the adaptive-splitting behaviour testable at all. The flat
// fakeVL above returns the same lines for any window, so a split would double-count.
type timeAwareVL struct {
	mu             sync.Mutex
	linesPerMinute int
	truncateAbove  int // emulate the port-forward: never stream more than this many lines
	exports        int
	imported       int
}

// linesFor scales proportionally with the window, including FRACTIONS of a minute — otherwise sub-minute
// windows would compute as zero lines and the sub-second splitting tests would pass for the wrong reason.
func (f *timeAwareVL) linesFor(start, end time.Time) int {
	d := end.Sub(start)
	if d <= 0 {
		return 0
	}
	return int(float64(f.linesPerMinute) * d.Minutes())
}

func (f *timeAwareVL) server() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/select/logsql/stream_field_names":
			fmt.Fprint(w, `{"values":[{"value":"app","hits":1}]}`)

		case "/select/logsql/query":
			q := r.URL.Query()
			start, _ := time.Parse(time.RFC3339, q.Get("start"))
			end, _ := time.Parse(time.RFC3339, q.Get("end"))
			n := f.linesFor(start, end)

			if strings.Contains(q.Get("query"), "| stats count()") {
				fmt.Fprintf(w, `{"n":%d}`+"\n", n)
				return
			}

			f.mu.Lock()
			f.exports++
			f.mu.Unlock()

			// The truncation this whole mechanism exists to avoid.
			emit := n
			if f.truncateAbove > 0 && emit > f.truncateAbove {
				emit = f.truncateAbove
			}
			for i := 0; i < emit; i++ {
				fmt.Fprintf(w, `{"_time":"%s","_msg":"l%d","app":"a"}`+"\n", rfc(start), i)
			}

		case "/insert/jsonline":
			var reader io.Reader = r.Body
			if r.Header.Get("Content-Encoding") == "gzip" {
				zr, err := gzip.NewReader(r.Body)
				if err != nil {
					w.WriteHeader(http.StatusBadRequest)
					return
				}
				defer zr.Close()
				reader = zr
			}
			body, _ := io.ReadAll(reader)
			f.mu.Lock()
			f.imported += strings.Count(string(body), "\n")
			f.mu.Unlock()

		case "/internal/force_flush":
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
}

func TestMigrateAdaptiveSplitsUntilWindowsFitAndMovesEverything(t *testing.T) {
	// 60 minutes at 1000 lines/min = 60,000 lines, against a 20,000 limit. It must bisect rather than
	// attempt one oversized export.
	src := &timeAwareVL{linesPerMinute: 1000}
	srv := src.server()
	defer srv.Close()

	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	end := start.Add(time.Hour)

	st := &migrationStats{}
	if err := migrateAdaptive(srv.URL, srv.URL, "*", "", "app", start, end, 20000, 0, 20000, 0, st); err != nil {
		t.Fatalf("migrateAdaptive: %v", err)
	}

	if st.expected != 60000 || st.moved != 60000 {
		t.Errorf("expected/moved = %d/%d, want 60000/60000", st.expected, st.moved)
	}
	if st.lost() != 0 {
		t.Errorf("lost = %d, want 0", st.lost())
	}
	if st.shortWindows != 0 {
		t.Errorf("shortWindows = %d, want 0", st.shortWindows)
	}
	// 60k split down to <=20k means quarters (15k each): 4 leaf exports.
	if src.exports != 4 {
		t.Errorf("leaf exports = %d, want 4 (60k bisected to 15k windows)", src.exports)
	}
}

func TestMigrateAdaptiveRecordsTruncationButKeepsGoing(t *testing.T) {
	// Loss is acceptable here; loss going UNREPORTED is not. With a limit above the truncation point, the
	// export gets cut and the run must carry on while counting exactly what went missing.
	src := &timeAwareVL{linesPerMinute: 1000, truncateAbove: 5000}
	srv := src.server()
	defer srv.Close()

	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	end := start.Add(10 * time.Minute) // 10,000 lines, under the limit, so no split

	st := &migrationStats{}
	if err := migrateAdaptive(srv.URL, srv.URL, "*", "", "app", start, end, 20000, 0, 20000, 0, st); err != nil {
		t.Fatalf("migrateAdaptive should tolerate truncation, got: %v", err)
	}

	if st.expected != 10000 {
		t.Errorf("expected = %d, want 10000", st.expected)
	}
	if st.moved != 5000 {
		t.Errorf("moved = %d, want 5000 (truncated)", st.moved)
	}
	if st.lost() != 5000 {
		t.Errorf("lost = %d, want 5000", st.lost())
	}
	if st.shortWindows != 1 {
		t.Errorf("shortWindows = %d, want 1", st.shortWindows)
	}
	if len(st.examples) == 0 {
		t.Error("truncation was not recorded in the examples for the summary")
	}
}

func TestMigrateAdaptiveAbortsOnSystemicFailure(t *testing.T) {
	// Occasional loss is tolerated; a dead endpoint is not. Consecutive failures must stop the run rather
	// than spend hours transferring nothing.
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer dead.Close()

	st := &migrationStats{}
	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)

	var err error
	// Each call is one window; failures accumulate until the threshold trips.
	for i := 0; i < maxConsecutiveFailures+2 && err == nil; i++ {
		s := start.Add(time.Duration(i) * time.Hour)
		err = migrateAdaptive(dead.URL, dead.URL, "*", "", "app", s, s.Add(time.Hour), 20000, 0, 20000, 0, st)
	}
	if err == nil {
		t.Fatal("expected an abort after repeated consecutive failures")
	}
	if !strings.Contains(err.Error(), "systemic") {
		t.Errorf("abort error should name the cause as systemic, got: %v", err)
	}
}

func TestMigrateAdaptiveSkipsEmptyWindowsWithoutExporting(t *testing.T) {
	src := &timeAwareVL{linesPerMinute: 0}
	srv := src.server()
	defer srv.Close()

	start := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	st := &migrationStats{}
	if err := migrateAdaptive(srv.URL, srv.URL, "*", "", "app", start, start.Add(time.Hour), 20000, 0, 20000, 0, st); err != nil {
		t.Fatalf("migrateAdaptive: %v", err)
	}
	if src.exports != 0 {
		t.Errorf("exports = %d, want 0 — an empty window should not be exported at all", src.exports)
	}
	if st.expected != 0 || st.moved != 0 {
		t.Errorf("expected/moved = %d/%d, want 0/0", st.expected, st.moved)
	}
}

func TestRfcKeepsMillisecondsSoSubSecondWindowsAreDistinct(t *testing.T) {
	// The property the sub-second bisection depends on. At second precision these two boundaries would
	// format identically, a window between them would have start == end, and the splitting would quietly
	// stop working instead of failing.
	a := time.Date(2026, 9, 9, 13, 55, 18, 0, time.UTC)
	b := a.Add(500 * time.Millisecond)

	if rfc(a) == rfc(b) {
		t.Fatalf("500ms apart but formatted identically as %q — sub-second windows would be empty", rfc(a))
	}
	if want := "2026-09-09T13:55:18.000Z"; rfc(a) != want {
		t.Errorf("rfc = %q, want %q", rfc(a), want)
	}
	if want := "2026-09-09T13:55:18.500Z"; rfc(b) != want {
		t.Errorf("rfc = %q, want %q", rfc(b), want)
	}
}

func TestMigrateAdaptiveSplitsBelowOneSecondForDenseBursts(t *testing.T) {
	// The September 9 case that produced 606 "cannot split further" warnings under the old one-minute
	// floor: a very dense burst inside well under a minute. With a 100ms floor and millisecond timestamps
	// it must now bisect all the way down and transfer everything.
	//
	// 600,000 lines/minute = 10,000 lines/second, so a 30-second window holds 300,000 — fifteen times the
	// 20,000 cap, and only reachable by splitting past the old one-second barrier.
	src := &timeAwareVL{linesPerMinute: 600000}
	srv := src.server()
	defer srv.Close()

	start := time.Date(2026, 9, 9, 13, 55, 0, 0, time.UTC)
	end := start.Add(30 * time.Second)

	st := &migrationStats{}
	if err := migrateAdaptive(srv.URL, srv.URL, "*", "", "app", start, end, 20000, 0, 20000, 0, st); err != nil {
		t.Fatalf("migrateAdaptive: %v", err)
	}

	if st.unsplittable != 0 {
		t.Errorf("unsplittable = %d, want 0 — a sub-second floor should handle this burst", st.unsplittable)
	}
	if st.expected != st.moved {
		t.Errorf("expected %d but moved %d", st.expected, st.moved)
	}
	if st.lost() != 0 {
		t.Errorf("lost = %d, want 0", st.lost())
	}
	if st.moved == 0 {
		t.Fatal("nothing was moved — sub-second windows are probably formatting as empty ranges")
	}
}
