package agent

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

const sseTurn = `data: {"author":"business_insights","content":{"role":"model","parts":[{"function_call":{"name":"read_business_glossary","args":{}}}]}}

data: {"author":"business_insights","content":{"role":"user","parts":[{"function_response":{"name":"read_business_glossary"}}]}}

: keep-alive

data: {"author":"business_insights","content":{"role":"model","parts":[{"thought":true,"text":"thinking..."},{"text":"Revenue last month was "},{"text":"$1,234."}]}}

`

func TestParseStreamAndSummarize(t *testing.T) {
	events, err := ParseStream(strings.NewReader(sseTurn))
	if err != nil {
		t.Fatal(err)
	}
	if len(events) != 3 {
		t.Fatalf("got %d events, want 3", len(events))
	}
	a := Summarize(events)
	if a.Text != "Revenue last month was $1,234." {
		t.Fatalf("Text = %q", a.Text)
	}
	if !reflect.DeepEqual(a.Tools, []string{"read_business_glossary"}) {
		t.Fatalf("Tools = %v", a.Tools)
	}
	if a.Error != "" {
		t.Fatalf("Error = %q", a.Error)
	}
}

func TestParseStreamNDJSON(t *testing.T) {
	ndjson := `{"content":{"role":"model","parts":[{"text":"hello"}]}}` + "\n"
	events, err := ParseStream(strings.NewReader(ndjson))
	if err != nil || len(events) != 1 || Summarize(events).Text != "hello" {
		t.Fatalf("events=%v err=%v", events, err)
	}
}

func TestSummarizeError(t *testing.T) {
	a := Summarize([]Event{{ErrorCode: "SAFETY", ErrorMessage: "blocked by Model Armor"}})
	if a.Error != "SAFETY blocked by Model Armor" || a.Text != "" {
		t.Fatalf("got %+v", a)
	}
}

type recorded struct {
	path string
	body map[string]any
}

func fakeEngine(t *testing.T, getStatus int) (*httptest.Server, *[]recorded) {
	t.Helper()
	var calls []recorded
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		data, _ := io.ReadAll(r.Body)
		var body map[string]any
		_ = json.Unmarshal(data, &body)
		calls = append(calls, recorded{path: r.URL.Path + "?" + r.URL.RawQuery, body: body})
		switch body["class_method"] {
		case "async_get_session":
			if getStatus != http.StatusOK {
				http.Error(w, `{"error":{"message":"not found"}}`, getStatus)
				return
			}
			_, _ = w.Write([]byte(`{"output":{"id":"s-1"}}`))
		case "async_create_session":
			_, _ = w.Write([]byte(`{"output":{"id":"s-1"}}`))
		case "async_stream_query":
			_, _ = w.Write([]byte(sseTurn))
		default:
			http.Error(w, "unexpected", http.StatusBadRequest)
		}
	}))
	t.Cleanup(srv.Close)
	return srv, &calls
}

func TestEnsureSessionCreatesOnlyWhenMissing(t *testing.T) {
	for _, tc := range []struct {
		name      string
		getStatus int
		methods   []string
	}{
		{"exists", http.StatusOK, []string{"async_get_session"}},
		{"missing", http.StatusInternalServerError, []string{"async_get_session", "async_create_session"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv, calls := fakeEngine(t, tc.getStatus)
			c := &Client{Endpoint: srv.URL + "/v1", Resource: "projects/p/locations/l/reasoningEngines/1", HTTP: srv.Client()}
			if err := c.EnsureSession(context.Background(), "slack-t-u", "s-1"); err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, call := range *calls {
				got = append(got, call.body["class_method"].(string))
				if !strings.HasSuffix(call.path, ":query?") {
					t.Fatalf("session call went to %q", call.path)
				}
				input := call.body["input"].(map[string]any)
				if input["user_id"] != "slack-t-u" || input["session_id"] != "s-1" {
					t.Fatalf("input = %v", input)
				}
			}
			if !reflect.DeepEqual(got, tc.methods) {
				t.Fatalf("methods = %v, want %v", got, tc.methods)
			}
		})
	}
}

func TestAsk(t *testing.T) {
	srv, calls := fakeEngine(t, http.StatusOK)
	c := &Client{Endpoint: srv.URL + "/v1", Resource: "projects/p/locations/l/reasoningEngines/1", HTTP: srv.Client()}
	a, err := c.Ask(context.Background(), "slack-t-u", "s-1", "revenue last month?")
	if err != nil {
		t.Fatal(err)
	}
	if a.Text != "Revenue last month was $1,234." {
		t.Fatalf("Text = %q", a.Text)
	}
	call := (*calls)[0]
	if call.path != "/v1/projects/p/locations/l/reasoningEngines/1:streamQuery?alt=sse" {
		t.Fatalf("path = %q", call.path)
	}
	if call.body["input"].(map[string]any)["message"] != "revenue last month?" {
		t.Fatalf("body = %v", call.body)
	}
}
