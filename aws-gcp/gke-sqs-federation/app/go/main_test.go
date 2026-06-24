package main

import (
	"testing"
	"time"
)

func TestDurationEnv(t *testing.T) {
	cases := []struct {
		name string
		set  string
		def  time.Duration
		want time.Duration
	}{
		{name: "unset uses default", set: "", def: 5 * time.Second, want: 5 * time.Second},
		{name: "plain seconds integer", set: "10", def: 5 * time.Second, want: 10 * time.Second},
		{name: "go duration string", set: "2m", def: 5 * time.Second, want: 2 * time.Minute},
		{name: "garbage falls back to default", set: "not-a-duration", def: 3 * time.Second, want: 3 * time.Second},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("SEND_INTERVAL", tc.set)
			got := durationEnv("SEND_INTERVAL", tc.def)
			if got != tc.want {
				t.Fatalf("durationEnv(%q, %s) = %s, want %s", tc.set, tc.def, got, tc.want)
			}
		})
	}
}

// run must reject an unset QUEUE_URL before attempting any AWS calls.
func TestRunRequiresQueueURL(t *testing.T) {
	t.Setenv("QUEUE_URL", "")
	t.Setenv("MODE", "writer")
	if err := run(); err == nil {
		t.Fatal("expected an error when QUEUE_URL is unset, got nil")
	}
}
