package main

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"
)

// One client for everything, with a ceiling generous enough for the longest operation in the lab
// (exporting a day of logs or a week of series). It is a ceiling, not a delay — short calls still return
// as soon as they are done.
var httpClient = &http.Client{Timeout: 30 * time.Minute}

// Addresses that live on the far side of the cross-cloud VPN. Registered by whichever subcommand knows
// which of its endpoints is remote, so that a connection failure can say so instead of leaving the
// reader to guess whether the fault is in-cluster or in the tunnel. That guess is the single most
// time-consuming wrong turn available here.
var remoteHosts []string

func registerRemote(rawURL string) {
	if h := hostOf(rawURL); h != "" {
		remoteHosts = append(remoteHosts, h)
	}
}

func hostOf(rawURL string) string {
	u, err := url.Parse(rawURL)
	if err != nil {
		return ""
	}
	return u.Host
}

// netErr annotates a transport failure with where the address lives.
func netErr(rawURL string, err error) error {
	for _, h := range remoteHosts {
		if hostOf(rawURL) == h {
			return fmt.Errorf("%s: %w\n       This address is on the far side of the cross-cloud VPN. "+
				"Check `task vpn-status` before suspecting the data", rawURL, err)
		}
	}
	return fmt.Errorf("%s: %w", rawURL, err)
}

// httpErr turns a non-2xx response into an error carrying enough of the body to diagnose it. Both
// VictoriaMetrics and VictoriaLogs explain rejected writes in the body, so discarding it would throw away
// the answer.
func httpErr(rawURL string, resp *http.Response) error {
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 2048))
	return fmt.Errorf("%s: HTTP %d\n%s", rawURL, resp.StatusCode, strings.TrimSpace(string(body)))
}

func post(rawURL string, body []byte, contentType string) error {
	return doPost(rawURL, body, contentType, false)
}

// postGzip compresses the body before sending it.
//
// This is the difference between an afternoon and a working day when the transfer crosses a home
// connection. Kubernetes log lines repeat the same pod metadata on every entry — container id, node name,
// the full pod label set — so they compress roughly 29x in practice. Measured on real data: 5.14 MB of
// JSON became 177 KB.
//
// The READ side already benefits without any help: Go's HTTP transport adds `Accept-Encoding: gzip`
// automatically and decompresses transparently, and VictoriaLogs honours it. Only the write side needed
// doing, because a request body is never compressed unless the client chooses to.
func postGzip(rawURL string, body []byte, contentType string) error {
	return doPost(rawURL, body, contentType, true)
}

func doPost(rawURL string, body []byte, contentType string, compress bool) error {
	payload := body
	if compress && len(body) > 0 {
		var buf bytes.Buffer
		zw := gzip.NewWriter(&buf)
		if _, err := zw.Write(body); err != nil {
			return fmt.Errorf("compressing request body: %w", err)
		}
		if err := zw.Close(); err != nil {
			return fmt.Errorf("finishing compressed request body: %w", err)
		}
		payload = buf.Bytes()
	}

	req, err := http.NewRequest(http.MethodPost, rawURL, bytes.NewReader(payload))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", contentType)
	if compress && len(body) > 0 {
		req.Header.Set("Content-Encoding", "gzip")
	}
	// Set explicitly so the transport can retry idempotently and so the server sees a real length rather
	// than a chunked stream of unknown size.
	req.ContentLength = int64(len(payload))

	resp, err := httpClient.Do(req)
	if err != nil {
		return netErr(rawURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		return httpErr(rawURL, resp)
	}
	_, err = io.Copy(io.Discard, resp.Body)
	return err
}

func getBytes(rawURL string) ([]byte, error) {
	resp, err := httpClient.Get(rawURL)
	if err != nil {
		return nil, netErr(rawURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		return nil, httpErr(rawURL, resp)
	}
	return io.ReadAll(resp.Body)
}

func getJSON(rawURL string, out any) error {
	body, err := getBytes(rawURL)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(body, out); err != nil {
		return fmt.Errorf("%s: decoding response: %w", rawURL, err)
	}
	return nil
}

// eachLine streams a JSON-lines response, handing one line at a time to fn.
//
// Both /api/v1/export and /select/logsql/query emit results as they are found rather than buffering a
// complete response, so consuming them line by line keeps memory bounded no matter how much data the
// window holds.
//
// The scanner buffer is raised deliberately. bufio.Scanner refuses tokens longer than 64 KiB by default
// and reports that as an error partway through an otherwise healthy stream — and a single log entry
// carrying a stack trace or a fat set of Kubernetes labels can exceed it. Truncating a migration at the
// first unusually long line would be a silent-looking data loss.
func eachLine(rawURL string, fn func(line []byte) error) error {
	resp, err := httpClient.Get(rawURL)
	if err != nil {
		return netErr(rawURL, err)
	}
	defer resp.Body.Close()

	if resp.StatusCode/100 != 2 {
		return httpErr(rawURL, resp)
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 0, 1<<20), 16<<20) // 1 MiB start, 16 MiB per-line ceiling

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(strings.TrimSpace(string(line))) == 0 {
			continue
		}
		// The scanner reuses its buffer between iterations, so anything retained past this call must be
		// copied. Callers that only parse are safe; callers that keep bytes must copy.
		if err := fn(line); err != nil {
			return err
		}
	}
	if err := scanner.Err(); err != nil {
		return fmt.Errorf("%s: reading response stream: %w", rawURL, err)
	}
	return nil
}

// forceFlush makes recent writes immediately queryable.
//
// The ingestion endpoints of both databases acknowledge RECEIPT, not durability: data lands in an
// in-memory buffer first, and a query issued straight afterwards can legitimately return nothing. Every
// step here is followed immediately by another that reads what it just wrote, so flushing removes a race
// that would otherwise look like missing data.
//
// Best effort: a failure here is worth a warning, not an abort.
func forceFlush(baseURL string) {
	if err := post(strings.TrimRight(baseURL, "/")+"/internal/force_flush", nil, "text/plain"); err != nil {
		logf("    (warning: force_flush on %s failed: %v; recent writes may lag a few seconds)", baseURL, err)
	}
}

// multisetDiff compares two multisets, returning how many entries are missing from b, how many are
// unexpected in b, and a few examples of each.
//
// A MULTISET RATHER THAN A SET, deliberately. Duplicates are exactly the failure a repeated log
// migration produces, and set comparison would collapse them and report success.
func multisetDiff[K comparable](a, b map[K]int, maxExamples int) (missing, extra int, missingEx, extraEx []K) {
	for k, na := range a {
		if d := na - b[k]; d > 0 {
			missing += d
			if len(missingEx) < maxExamples {
				missingEx = append(missingEx, k)
			}
		}
	}
	for k, nb := range b {
		if d := nb - a[k]; d > 0 {
			extra += d
			if len(extraEx) < maxExamples {
				extraEx = append(extraEx, k)
			}
		}
	}
	return missing, extra, missingEx, extraEx
}
