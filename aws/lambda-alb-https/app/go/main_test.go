package main

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/aws/aws-lambda-go/events"
)

func TestHandlerHello(t *testing.T) {
	resp, err := handler(context.Background(), events.ALBTargetGroupRequest{Path: "/"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", resp.StatusCode)
	}
	if !strings.Contains(resp.Body, "Hello, world") {
		t.Fatalf("expected greeting in body, got %q", resp.Body)
	}
}

func TestHandlerHealthz(t *testing.T) {
	resp, err := handler(context.Background(), events.ALBTargetGroupRequest{Path: "/healthz"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("expected status 200, got %d", resp.StatusCode)
	}
	if !strings.Contains(resp.Body, "ok") {
		t.Fatalf("expected health body, got %q", resp.Body)
	}
}

func TestHandlerNotFound(t *testing.T) {
	resp, err := handler(context.Background(), events.ALBTargetGroupRequest{Path: "/nope"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected status 404 for unknown path, got %d", resp.StatusCode)
	}
}
