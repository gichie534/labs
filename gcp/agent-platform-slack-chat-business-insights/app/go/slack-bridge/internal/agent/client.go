// Package agent calls an ADK agent deployed on Agent Runtime over REST.
//
//	POST https://<region>-aiplatform.googleapis.com/v1/<engine>:query              (session class methods)
//	POST https://<region>-aiplatform.googleapis.com/v1/<engine>:streamQuery?alt=sse (async_stream_query)
//
// Calls go to the engine, so the engine's traffic split decides which revision answers. The caller authenticates
// with its own Google identity (the worker's service account), which needs roles/aiplatform.user on the engine.
package agent

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
)

// Client calls one reasoning engine.
type Client struct {
	// Endpoint is the API base, e.g. https://us-central1-aiplatform.googleapis.com/v1.
	Endpoint string
	// Resource is the engine's full resource name.
	Resource string
	// HTTP must attach Google credentials (e.g. oauth2.NewClient with google.DefaultTokenSource).
	HTTP *http.Client
}

// New returns a client for the engine in the given location.
func New(httpClient *http.Client, location, resource string) *Client {
	return &Client{
		Endpoint: fmt.Sprintf("https://%s-aiplatform.googleapis.com/v1", location),
		Resource: resource,
		HTTP:     httpClient,
	}
}

// Event is the subset of an ADK event the bridge uses.
type Event struct {
	Author       string   `json:"author"`
	Content      *Content `json:"content"`
	ErrorCode    string   `json:"error_code"`
	ErrorMessage string   `json:"error_message"`
}

// Content is a genai Content.
type Content struct {
	Role  string `json:"role"`
	Parts []Part `json:"parts"`
}

// Part is a genai Part.
type Part struct {
	Text         string        `json:"text"`
	Thought      bool          `json:"thought"`
	FunctionCall *FunctionCall `json:"function_call"`
}

// FunctionCall is a tool call made by the model.
type FunctionCall struct {
	Name string `json:"name"`
}

// Answer is the outcome of one turn.
type Answer struct {
	Text  string
	Tools []string
	// Error is set when the agent (or a guardrail such as Model Armor) ended the turn with an error event.
	Error string
}

// EnsureSession makes sure the session exists, creating it with the given ID on first use.
func (c *Client) EnsureSession(ctx context.Context, userID, sessionID string) error {
	input := map[string]any{"user_id": userID, "session_id": sessionID}
	if _, err := c.query(ctx, "async_get_session", input); err == nil {
		return nil
	}
	if _, err := c.query(ctx, "async_create_session", input); err != nil {
		return fmt.Errorf("create session %s: %w", sessionID, err)
	}
	return nil
}

// Ask sends one message in the session and collects the streamed events into an Answer.
func (c *Client) Ask(ctx context.Context, userID, sessionID, message string) (Answer, error) {
	body, err := json.Marshal(map[string]any{
		"class_method": "async_stream_query",
		"input":        map[string]any{"user_id": userID, "session_id": sessionID, "message": message},
	})
	if err != nil {
		return Answer{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.Endpoint+"/"+c.Resource+":streamQuery?alt=sse", bytes.NewReader(body))
	if err != nil {
		return Answer{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return Answer{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		msg, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return Answer{}, fmt.Errorf("streamQuery: %s: %s", resp.Status, strings.TrimSpace(string(msg)))
	}
	events, err := ParseStream(resp.Body)
	if err != nil {
		return Answer{}, err
	}
	return Summarize(events), nil
}

func (c *Client) query(ctx context.Context, method string, input map[string]any) (json.RawMessage, error) {
	body, err := json.Marshal(map[string]any{"class_method": method, "input": input})
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, c.Endpoint+"/"+c.Resource+":query", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := c.HTTP.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: %s: %s", method, resp.Status, strings.TrimSpace(string(data)))
	}
	var out struct {
		Output json.RawMessage `json:"output"`
	}
	if err := json.Unmarshal(data, &out); err != nil {
		return nil, fmt.Errorf("%s: decode response: %w", method, err)
	}
	if len(out.Output) == 0 || string(out.Output) == "null" {
		return nil, fmt.Errorf("%s: empty output", method)
	}
	return out.Output, nil
}

// ParseStream reads streamQuery output. With alt=sse each event is a "data: {...}" line; without it, one JSON
// object per line. Both are accepted. Lines that aren't events (comments, keep-alives) are skipped.
func ParseStream(r io.Reader) ([]Event, error) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 0, 64*1024), 8<<20)
	var events []Event
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, ":") || strings.HasPrefix(line, "event:") {
			continue
		}
		line = strings.TrimSpace(strings.TrimPrefix(line, "data:"))
		if !strings.HasPrefix(line, "{") {
			continue
		}
		var ev Event
		if err := json.Unmarshal([]byte(line), &ev); err != nil {
			continue
		}
		events = append(events, ev)
	}
	return events, scanner.Err()
}

// Summarize turns a turn's events into the answer: the text of the last model event that has any (thoughts
// excluded), the tools called, and the last error event, if any.
func Summarize(events []Event) Answer {
	var a Answer
	for _, ev := range events {
		if ev.ErrorCode != "" || ev.ErrorMessage != "" {
			a.Error = strings.TrimSpace(ev.ErrorCode + " " + ev.ErrorMessage)
		}
		if ev.Content == nil {
			continue
		}
		for _, p := range ev.Content.Parts {
			if p.FunctionCall != nil && p.FunctionCall.Name != "" {
				a.Tools = append(a.Tools, p.FunctionCall.Name)
			}
		}
	}
	for i := len(events) - 1; i >= 0; i-- {
		c := events[i].Content
		if c == nil || (c.Role != "" && c.Role != "model") {
			continue
		}
		var b strings.Builder
		for _, p := range c.Parts {
			if p.Text != "" && !p.Thought {
				b.WriteString(p.Text)
			}
		}
		if text := strings.TrimSpace(b.String()); text != "" {
			a.Text = text
			break
		}
	}
	return a
}
