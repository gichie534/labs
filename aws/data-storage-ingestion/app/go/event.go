package main

import (
	"bytes"
	"encoding/csv"
	"encoding/json"
	"fmt"
	"math/rand"
	"strconv"
	"time"
)

// Event is the single record shape both ingestion paths carry. Identical on both sides on purpose —
// if the payloads differed, any measured difference between the paths could be blamed on the data
// rather than on the ingestion mechanism.
//
// The field is named event_time rather than `timestamp`: Redshift would accept a column called
// `timestamp`, but naming a column after a type is a trap, and JSON COPY with 'auto' matches JSON keys
// to column names, so the struct tag and the DDL have to agree.
type Event struct {
	UserID    int       `json:"user_id"`
	Event     string    `json:"event"`
	EventTime time.Time `json:"event_time"`
}

var (
	eventKinds = []string{"login", "logout", "purchase"}
	userIDs    = []int{1, 2, 3, 4}
)

// GenerateEvents builds n events stamped at the moment of generation. The caller decides what to do
// with them — write a CSV for the batch path, or put them on the stream one at a time.
func GenerateEvents(n int) []Event {
	events := make([]Event, 0, n)
	for i := 0; i < n; i++ {
		events = append(events, Event{
			UserID: userIDs[rand.Intn(len(userIDs))],
			Event:  eventKinds[rand.Intn(len(eventKinds))],
			// Truncated to the second: Redshift's TIMESTAMP holds microseconds, but whole seconds keep
			// the CSV and JSON forms byte-comparable and are plenty for measuring a 60s buffer.
			EventTime: time.Now().UTC().Truncate(time.Second),
		})
	}
	return events
}

// MarshalCSV renders events as CSV with a header row — the format the batch path uploads and the
// format `COPY ... FORMAT AS CSV IGNOREHEADER 1` expects.
func MarshalCSV(events []Event) ([]byte, error) {
	var buf bytes.Buffer
	w := csv.NewWriter(&buf)

	if err := w.Write([]string{"user_id", "event", "event_time"}); err != nil {
		return nil, fmt.Errorf("write csv header: %w", err)
	}
	for _, e := range events {
		row := []string{
			strconv.Itoa(e.UserID),
			e.Event,
			e.EventTime.Format(time.RFC3339),
		}
		if err := w.Write(row); err != nil {
			return nil, fmt.Errorf("write csv row: %w", err)
		}
	}

	w.Flush()
	if err := w.Error(); err != nil {
		return nil, fmt.Errorf("flush csv: %w", err)
	}
	return buf.Bytes(), nil
}

// MarshalRecord renders one event as a single JSON object followed by a newline.
//
// The trailing newline matters. Firehose concatenates the raw bytes of the records it buffers, so
// without a delimiter the delivered object is one run-on string of JSON objects that neither Redshift
// nor a human can read back.
func MarshalRecord(e Event) ([]byte, error) {
	b, err := json.Marshal(e)
	if err != nil {
		return nil, fmt.Errorf("marshal event: %w", err)
	}
	return append(b, '\n'), nil
}

// MaxEventTime returns the latest EventTime across events, and false when there are none.
func MaxEventTime(events []Event) (time.Time, bool) {
	if len(events) == 0 {
		return time.Time{}, false
	}
	max := events[0].EventTime
	for _, e := range events[1:] {
		if e.EventTime.After(max) {
			max = e.EventTime
		}
	}
	return max, true
}
