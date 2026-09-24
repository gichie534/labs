package main

// Tests for the parts of this program whose correctness the lab's conclusion rests on.
//
// The verification is the only thing standing between "the migration ran" and "the migration worked", so
// the cases below are mostly about making it FAIL when it should. A comparison that cannot detect a
// missing sample, a shifted timestamp, or a duplicated log line would report success on a broken
// migration, which is worse than having no check at all.
//
// These are pure unit tests with in-process HTTP stubs — no cluster, no cloud, no cost.

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// --- multiset semantics -----------------------------------------------------------------------------

func TestMultisetDiffDetectsDuplicates(t *testing.T) {
	// The case that justifies counting rather than using sets: a repeated log migration leaves a second
	// copy of every line. With set semantics the two sides would look equal.
	source := map[string]int{"a": 1, "b": 1}
	target := map[string]int{"a": 2, "b": 1}

	missing, extra, _, extraEx := multisetDiff(source, target, 5)
	if missing != 0 {
		t.Errorf("missing = %d, want 0", missing)
	}
	if extra != 1 {
		t.Errorf("extra = %d, want 1 (the duplicate of \"a\")", extra)
	}
	if len(extraEx) != 1 || extraEx[0] != "a" {
		t.Errorf("extraEx = %v, want [a]", extraEx)
	}
}

func TestMultisetDiffIdenticalIsClean(t *testing.T) {
	m := map[string]int{"a": 3, "b": 1}
	other := map[string]int{"b": 1, "a": 3}

	missing, extra, _, _ := multisetDiff(m, other, 5)
	if missing != 0 || extra != 0 {
		t.Errorf("identical multisets differed: missing=%d extra=%d", missing, extra)
	}
}

// --- series identity --------------------------------------------------------------------------------

func TestSeriesKeyIsOrderIndependent(t *testing.T) {
	a := seriesKey(map[string]string{"__name__": "m", "b": "2", "a": "1"})
	b := seriesKey(map[string]string{"a": "1", "__name__": "m", "b": "2"})
	if a != b {
		t.Fatalf("label order changed the identity:\n  %s\n  %s", a, b)
	}
	if want := `m{a=1,b=2}`; a != want {
		t.Errorf("seriesKey = %q, want %q", a, want)
	}
}

func TestSeriesKeyDistinguishesLabelValues(t *testing.T) {
	// Both clusters emit identically NAMED series; only labels tell them apart. Collapsing these would
	// make the live comparison meaningless.
	src := seriesKey(map[string]string{"__name__": "up", "cluster": "vmmig-source"})
	tgt := seriesKey(map[string]string{"__name__": "up", "cluster": "vmmig-target"})
	if src == tgt {
		t.Fatal("series differing only by label value produced the same key")
	}
}

// --- the metric gate --------------------------------------------------------------------------------

func seriesFixture(points ...sample) map[sample]int {
	out := map[sample]int{}
	for _, p := range points {
		out[p]++
	}
	return out
}

func TestDiffMetricsIdenticalPasses(t *testing.T) {
	data := map[string]map[sample]int{
		"m{series=s00}": seriesFixture(sample{1000, 1}, sample{2000, 2}),
	}
	// A distinct but equal copy, so the test cannot pass by comparing a map to itself.
	other := map[string]map[sample]int{
		"m{series=s00}": seriesFixture(sample{1000, 1}, sample{2000, 2}),
	}

	r := diffMetrics(data, other)
	if !r.ok {
		t.Fatalf("identical data reported a mismatch: diff=%d examples=%v", r.sampleDiff, r.examples)
	}
	if r.sourceSamples != 2 || r.targetSamples != 2 {
		t.Errorf("sample totals = %d/%d, want 2/2", r.sourceSamples, r.targetSamples)
	}
}

func TestDiffMetricsCatchesMissingSample(t *testing.T) {
	source := map[string]map[sample]int{
		"m{series=s00}": seriesFixture(sample{1000, 1}, sample{2000, 2}),
	}
	target := map[string]map[sample]int{
		"m{series=s00}": seriesFixture(sample{1000, 1}),
	}

	r := diffMetrics(source, target)
	if r.ok {
		t.Fatal("a dropped sample was reported as verified")
	}
	if r.sampleDiff != 1 {
		t.Errorf("sampleDiff = %d, want 1", r.sampleDiff)
	}
}

func TestDiffMetricsCatchesShiftedTimestamp(t *testing.T) {
	// The failure the whole lab is designed to rule out: data that arrived, but not at its original
	// time. A count-based check would pass this; an exact check must not.
	source := map[string]map[sample]int{
		"m{series=s00}": seriesFixture(sample{1000, 1}),
	}
	target := map[string]map[sample]int{
		"m{series=s00}": seriesFixture(sample{9999, 1}),
	}

	r := diffMetrics(source, target)
	if r.ok {
		t.Fatal("a re-stamped sample was reported as verified")
	}
	if r.sourceSamples != r.targetSamples {
		t.Errorf("sample COUNTS should match here (%d vs %d) — that is why counting alone is insufficient",
			r.sourceSamples, r.targetSamples)
	}
	if r.sampleDiff != 2 {
		t.Errorf("sampleDiff = %d, want 2 (one missing, one unexpected)", r.sampleDiff)
	}
}

func TestDiffMetricsCatchesAlteredValue(t *testing.T) {
	source := map[string]map[sample]int{"m{}": seriesFixture(sample{1000, 1})}
	target := map[string]map[sample]int{"m{}": seriesFixture(sample{1000, 1.5})}

	if r := diffMetrics(source, target); r.ok {
		t.Fatal("an altered value was reported as verified")
	}
}

func TestDiffMetricsCatchesMissingAndExtraSeries(t *testing.T) {
	source := map[string]map[sample]int{
		"m{series=s00}": seriesFixture(sample{1000, 1}),
		"m{series=s01}": seriesFixture(sample{1000, 1}),
	}
	target := map[string]map[sample]int{
		"m{series=s00}": seriesFixture(sample{1000, 1}),
		"m{series=s99}": seriesFixture(sample{1000, 1}),
	}

	r := diffMetrics(source, target)
	if r.ok {
		t.Fatal("mismatched series sets were reported as verified")
	}
	if len(r.onlySource) != 1 || r.onlySource[0] != "m{series=s01}" {
		t.Errorf("onlySource = %v, want [m{series=s01}]", r.onlySource)
	}
	if len(r.onlyTarget) != 1 || r.onlyTarget[0] != "m{series=s99}" {
		t.Errorf("onlyTarget = %v, want [m{series=s99}]", r.onlyTarget)
	}
}

func TestDiffMetricsEmptySourceIsNotSuccess(t *testing.T) {
	// Two empty databases are trivially "equal". Treating that as verified would turn "you forgot to
	// seed" into a green tick.
	r := diffMetrics(map[string]map[sample]int{}, map[string]map[sample]int{})
	if r.ok {
		t.Fatal("an empty source was reported as verified")
	}
}

func TestTimeBoundsReportsSecondsAcrossSeries(t *testing.T) {
	data := map[string]map[sample]int{
		"a{}": seriesFixture(sample{5000, 1}, sample{9000, 1}),
		"b{}": seriesFixture(sample{1000, 1}),
	}
	oldest, newest := timeBounds(data)
	if oldest != 1 || newest != 9 {
		t.Errorf("timeBounds = (%d, %d), want (1, 9) in seconds", oldest, newest)
	}
}

// --- the log gate -----------------------------------------------------------------------------------

func TestDiffLogsCatchesDuplicatedLine(t *testing.T) {
	// Exactly what a second, unguarded log migration produces.
	source := map[fingerprint]int{{ts: 1, seq: "0"}: 1}
	target := map[fingerprint]int{{ts: 1, seq: "0"}: 2}

	r := diffLogs(source, target)
	if r.ok {
		t.Fatal("a duplicated log line was reported as verified")
	}
	if r.diff != 1 {
		t.Errorf("diff = %d, want 1", r.diff)
	}
	if r.targetLines != 2 || r.sourceLines != 1 {
		t.Errorf("line totals = %d/%d, want 1/2", r.sourceLines, r.targetLines)
	}
}

func TestDiffLogsIdenticalPasses(t *testing.T) {
	source := map[fingerprint]int{{ts: 1, seq: "0"}: 1, {ts: 2, seq: "1"}: 1}
	target := map[fingerprint]int{{ts: 2, seq: "1"}: 1, {ts: 1, seq: "0"}: 1}

	if r := diffLogs(source, target); !r.ok {
		t.Fatalf("identical logs reported a mismatch: diff=%d", r.diff)
	}
}

func TestDiffLogsEmptySourceIsNotSuccess(t *testing.T) {
	if r := diffLogs(map[fingerprint]int{}, map[fingerprint]int{}); r.ok {
		t.Fatal("an empty source was reported as verified")
	}
}

// --- the deterministic seed -------------------------------------------------------------------------

func TestSampleValueIsDeterministicAndDistinct(t *testing.T) {
	if a, b := sampleValue(3, 7), sampleValue(3, 7); a != b {
		t.Fatalf("sampleValue is not deterministic: %d != %d", a, b)
	}
	// Distinct across both axes, so a series mix-up cannot hide behind equal values.
	seen := map[int64]string{}
	for s := 0; s < 12; s++ {
		for n := 0; n < 50; n++ {
			v := sampleValue(s, n)
			key := fmt.Sprintf("s%d/n%d", s, n)
			if prev, dup := seen[v]; dup {
				t.Fatalf("value %d produced by both %s and %s", v, prev, key)
			}
			seen[v] = key
		}
	}
}

func TestSampleValueIsExactlyRepresentableAsFloat64(t *testing.T) {
	// The reason values are integers: verification demands exact equality after a float64 round trip
	// through JSON. If a value could not survive that, the gate would be brittle rather than strict.
	for _, tc := range []struct{ series, index int }{{0, 0}, {11, 2015}, {5, 1000}} {
		v := sampleValue(tc.series, tc.index)
		if int64(float64(v)) != v {
			t.Errorf("sampleValue(%d,%d)=%d does not survive a float64 round trip", tc.series, tc.index, v)
		}
	}
}

// --- response parsing -------------------------------------------------------------------------------

func TestExportSeriesAggregatesMultipleBlocksPerSeries(t *testing.T) {
	// /api/v1/export may emit SEVERAL lines for one series, one per storage block. Assigning instead of
	// accumulating would silently discard all but the last block — losing real data while still
	// reporting a clean parse.
	body := strings.Join([]string{
		`{"metric":{"__name__":"m","series":"s00"},"values":[1,2],"timestamps":[1000,2000]}`,
		`{"metric":{"__name__":"m","series":"s00"},"values":[3],"timestamps":[3000]}`,
		`{"metric":{"__name__":"m","series":"s01"},"values":[9],"timestamps":[1000]}`,
	}, "\n") + "\n"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.URL.Query().Get("match[]"); got != seedMatch {
			t.Errorf("match[] = %q, want %q", got, seedMatch)
		}
		fmt.Fprint(w, body)
	}))
	defer srv.Close()

	out, err := exportSeries(srv.URL, seedMatch, "2026-01-01T00:00:00Z", "2026-01-02T00:00:00Z")
	if err != nil {
		t.Fatalf("exportSeries: %v", err)
	}
	if got := countSamples(out); got != 4 {
		t.Errorf("total samples = %d, want 4 (both blocks of s00 plus s01)", got)
	}
	if got := len(out["m{series=s00}"]); got != 3 {
		t.Errorf("s00 distinct samples = %d, want 3", got)
	}
}

func TestExportSeriesSurvivesMalformedLine(t *testing.T) {
	// A single unparseable line should not abort a migration-scale export.
	body := "not json\n" +
		`{"metric":{"__name__":"m"},"values":[1],"timestamps":[1000]}` + "\n"

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, body)
	}))
	defer srv.Close()

	out, err := exportSeries(srv.URL, seedMatch, "a", "b")
	if err != nil {
		t.Fatalf("exportSeries: %v", err)
	}
	if got := countSamples(out); got != 1 {
		t.Errorf("total samples = %d, want 1", got)
	}
}

func TestLogFingerprintsNormalisesSubSecondPrecision(t *testing.T) {
	// The two stores may render the same instant with different sub-second precision. That is a
	// formatting difference; treating it as a data difference would fail every migration.
	coarse := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"_time":"2026-01-01T00:00:00Z","seq":"7"}`+"\n")
	}))
	defer coarse.Close()

	fine := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"_time":"2026-01-01T00:00:00.123456789Z","seq":"7"}`+"\n")
	}))
	defer fine.Close()

	a, err := logFingerprints(coarse.URL, "x", "y")
	if err != nil {
		t.Fatalf("logFingerprints(coarse): %v", err)
	}
	b, err := logFingerprints(fine.URL, "x", "y")
	if err != nil {
		t.Fatalf("logFingerprints(fine): %v", err)
	}

	if r := diffLogs(a, b); !r.ok {
		t.Errorf("sub-second precision produced a false mismatch: diff=%d", r.diff)
	}
}

func TestLogFingerprintsDistinguishesDifferentSeconds(t *testing.T) {
	// The flip side: normalising to seconds must not blur genuinely different timestamps.
	a := map[fingerprint]int{{ts: 100, seq: "1"}: 1}
	b := map[fingerprint]int{{ts: 101, seq: "1"}: 1}
	if r := diffLogs(a, b); r.ok {
		t.Error("a one-second shift was reported as identical")
	}
}

func TestDiscoverStreamFieldsSortsAndJoins(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"values":[{"value":"service","hits":1},{"value":"dataset","hits":1},{"value":"","hits":0}]}`)
	}))
	defer srv.Close()

	got, err := discoverStreamFields(srv.URL, testWindowStart, testWindowEnd)
	if err != nil {
		t.Fatalf("discoverStreamFields: %v", err)
	}
	if want := "dataset,service"; got != want {
		t.Errorf("stream fields = %q, want %q (sorted, empties dropped)", got, want)
	}
}

func TestDiscoverStreamFieldsFailsLoudlyWhenSourceIsEmpty(t *testing.T) {
	// No stream fields means no logs. Proceeding would produce an import with no stream identity at all.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprint(w, `{"values":[]}`)
	}))
	defer srv.Close()

	if _, err := discoverStreamFields(srv.URL, testWindowStart, testWindowEnd); err == nil {
		t.Fatal("expected an error when the source reports no stream fields")
	}
}

func TestEachLineHandlesLinesBeyondTheDefaultScannerLimit(t *testing.T) {
	// bufio.Scanner refuses tokens over 64 KiB by default, and a log entry carrying a stack trace can
	// exceed that. Truncating a migration at the first long line would look like silent data loss.
	long := strings.Repeat("x", 200_000)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		fmt.Fprintf(w, "%s\nshort\n", long)
	}))
	defer srv.Close()

	var lengths []int
	if err := eachLine(srv.URL, func(line []byte) error {
		lengths = append(lengths, len(line))
		return nil
	}); err != nil {
		t.Fatalf("eachLine: %v", err)
	}
	if len(lengths) != 2 || lengths[0] != len(long) {
		t.Errorf("line lengths = %v, want [%d 5]", lengths, len(long))
	}
}

func TestPostSurfacesServerExplanation(t *testing.T) {
	// Both databases explain rejected writes in the response body. Discarding it would throw away the
	// answer to "why did the import fail".
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadRequest)
		fmt.Fprint(w, "cannot parse timestamp: too old for retention")
	}))
	defer srv.Close()

	err := post(srv.URL, []byte("x"), "text/plain")
	if err == nil {
		t.Fatal("expected an error for a 400 response")
	}
	if !strings.Contains(err.Error(), "too old for retention") {
		t.Errorf("error lost the server's explanation: %v", err)
	}
}

func TestNetErrFlagsAddressesAcrossTheVPN(t *testing.T) {
	// A connection failure to the far cloud should say so. Guessing whether a fault is in-cluster or in
	// the tunnel is the most time-consuming wrong turn available in this lab.
	saved := remoteHosts
	defer func() { remoteHosts = saved }()
	remoteHosts = nil

	registerRemote("http://internal-abc.elb.amazonaws.com:8428")
	remote := netErr("http://internal-abc.elb.amazonaws.com:8428/api/v1/export", fmt.Errorf("i/o timeout"))
	if !strings.Contains(remote.Error(), "vpn-status") {
		t.Errorf("remote error lacked the VPN hint: %v", remote)
	}

	local := netErr("http://vmsingle-endpoint.observability.svc:8428/x", fmt.Errorf("i/o timeout"))
	if strings.Contains(local.Error(), "vpn-status") {
		t.Errorf("in-cluster error wrongly blamed the VPN: %v", local)
	}
}

// A fixed window for the tests that need one. The stubs ignore it; only its presence matters.
var (
	testWindowStart = time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	testWindowEnd   = time.Date(2026, 1, 2, 0, 0, 0, 0, time.UTC)
)
