package worker

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/agent"
	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/job"
)

type fakeAgent struct {
	answer             agent.Answer
	err                error
	sessions, messages []string
}

func (f *fakeAgent) EnsureSession(_ context.Context, userID, sessionID string) error {
	f.sessions = append(f.sessions, userID+"|"+sessionID)
	return nil
}

func (f *fakeAgent) Ask(_ context.Context, _, _, message string) (agent.Answer, error) {
	f.messages = append(f.messages, message)
	return f.answer, f.err
}

type fakeSlack struct {
	replies   []string
	reactions []string
}

func (s *fakeSlack) Reply(_ context.Context, channel, threadTS, text string) error {
	s.replies = append(s.replies, channel+"|"+threadTS+"|"+text)
	return nil
}
func (s *fakeSlack) React(_ context.Context, _, _, emoji string) error {
	s.reactions = append(s.reactions, "+"+emoji)
	return nil
}
func (s *fakeSlack) Unreact(_ context.Context, _, _, emoji string) error {
	s.reactions = append(s.reactions, "-"+emoji)
	return nil
}

func push(t *testing.T, q job.Question) *http.Request {
	t.Helper()
	data, _ := q.Marshal()
	body, _ := json.Marshal(map[string]any{
		"message":      map[string]any{"data": base64.StdEncoding.EncodeToString(data), "messageId": "m-1"},
		"subscription": "projects/p/subscriptions/s",
	})
	return httptest.NewRequest(http.MethodPost, "/pubsub/push", bytes.NewReader(body))
}

var question = job.Question{
	EventID: "Ev1", Team: "T1", Channel: "C1", User: "U1",
	Text: "revenue last month?", MessageTS: "111.222", ThreadTS: "111.000",
}

func newHandler(a Agent, s *fakeSlack) *Handler {
	return &Handler{
		Agent: a,
		Slack: func(context.Context) (Slack, error) { return s, nil },
		Log:   slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

func TestAnswersInThreadWithSessionPerThread(t *testing.T) {
	a := &fakeAgent{answer: agent.Answer{Text: "Revenue was **$1,234**."}}
	s := &fakeSlack{}
	rec := httptest.NewRecorder()
	newHandler(a, s).ServeHTTP(rec, push(t, question))

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d", rec.Code)
	}
	if got, want := a.sessions, []string{"slack-t1-u1|s-t1-c1-111-000"}; len(got) != 1 || got[0] != want[0] {
		t.Fatalf("sessions = %v, want %v", got, want)
	}
	if len(s.replies) != 1 || s.replies[0] != "C1|111.000|Revenue was *$1,234*." {
		t.Fatalf("replies = %v", s.replies)
	}
	if strings.Join(s.reactions, ",") != "+hourglass_flowing_sand,-hourglass_flowing_sand" {
		t.Fatalf("reactions = %v", s.reactions)
	}
}

func TestAgentFailureIsAcknowledgedWithOneApology(t *testing.T) {
	a := &fakeAgent{err: errors.New("503 unavailable")}
	s := &fakeSlack{}
	rec := httptest.NewRecorder()
	newHandler(a, s).ServeHTTP(rec, push(t, question))

	if rec.Code != http.StatusNoContent {
		t.Fatalf("status = %d, want 204 (no redelivery)", rec.Code)
	}
	if len(s.replies) != 1 || !strings.Contains(s.replies[0], "couldn't answer") {
		t.Fatalf("replies = %v", s.replies)
	}
}

func TestGuardrailBlockGetsPoliteRefusal(t *testing.T) {
	a := &fakeAgent{answer: agent.Answer{Error: "SAFETY blocked"}}
	s := &fakeSlack{}
	newHandler(a, s).ServeHTTP(httptest.NewRecorder(), push(t, question))
	if len(s.replies) != 1 || !strings.Contains(s.replies[0], "can't help") {
		t.Fatalf("replies = %v", s.replies)
	}
}

func TestMalformedMessagesAreDropped(t *testing.T) {
	a := &fakeAgent{}
	s := &fakeSlack{}
	for _, body := range []string{"not json", `{"message":{"data":"%%%"}}`, `{"message":{"data":"e30="}}`} {
		rec := httptest.NewRecorder()
		newHandler(a, s).ServeHTTP(rec, httptest.NewRequest(http.MethodPost, "/pubsub/push", strings.NewReader(body)))
		if rec.Code != http.StatusNoContent {
			t.Fatalf("body %q: status = %d, want 204", body, rec.Code)
		}
	}
	if len(a.messages) != 0 || len(s.replies) != 0 {
		t.Fatalf("malformed input reached the agent or Slack: %v %v", a.messages, s.replies)
	}
}
