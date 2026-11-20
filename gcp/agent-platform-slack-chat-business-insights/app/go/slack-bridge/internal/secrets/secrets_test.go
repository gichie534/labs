package secrets

import (
	"context"
	"testing"
	"time"
)

type countingSource struct{ calls int }

func (s *countingSource) Get(_ context.Context, name string) (string, error) {
	s.calls++
	return "value-of-" + name, nil
}

func TestCachedRefetchesAfterTTL(t *testing.T) {
	now := time.Unix(0, 0)
	src := &countingSource{}
	c := &Cached{Source: src, TTL: time.Minute, Now: func() time.Time { return now }}

	for i := 0; i < 3; i++ {
		v, err := c.Get(context.Background(), "s")
		if err != nil || v != "value-of-s" {
			t.Fatalf("Get = %q, %v", v, err)
		}
	}
	if src.calls != 1 {
		t.Fatalf("calls = %d, want 1 (cached)", src.calls)
	}
	now = now.Add(2 * time.Minute)
	if _, err := c.Get(context.Background(), "s"); err != nil {
		t.Fatal(err)
	}
	if src.calls != 2 {
		t.Fatalf("calls = %d, want 2 after TTL", src.calls)
	}
}
