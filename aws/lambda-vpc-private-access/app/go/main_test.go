package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
)

// TestHandleReachesBackend stands up a fake backend and asserts the handler GETs it and passes the
// body through — the app-level analogue of the lab's end-to-end proof.
func TestHandleReachesBackend(t *testing.T) {
	backend := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"message":"hello from a private EC2 instance"}`))
	}))
	defer backend.Close()

	t.Setenv("TARGET_URL", backend.URL)

	resp, err := handle(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !resp.OK {
		t.Fatalf("expected ok, got: %+v", resp)
	}

	var backendBody map[string]string
	if err := json.Unmarshal(resp.Backend, &backendBody); err != nil {
		t.Fatalf("backend body not JSON: %v", err)
	}
	if backendBody["message"] == "" {
		t.Fatalf("expected a message from backend, got: %s", resp.Backend)
	}
}

// TestHandleMissingTarget checks the graceful path when TARGET_URL is unset.
func TestHandleMissingTarget(t *testing.T) {
	os.Unsetenv("TARGET_URL")

	resp, err := handle(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.OK || resp.Error == "" {
		t.Fatalf("expected failure when TARGET_URL unset, got: %+v", resp)
	}
}
