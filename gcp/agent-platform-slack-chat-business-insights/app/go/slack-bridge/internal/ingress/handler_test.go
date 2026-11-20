package ingress

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/job"
)

const secret = "test-signing-secret"

type fakePublisher struct{ queued []job.Question }

func (p *fakePublisher) Publish(_ context.Context, q job.Question) error {
	p.queued = append(p.queued, q)
	return nil
}

func signed(t *testing.T, body string, sign string) *http.Request {
	t.Helper()
	ts := strconv.FormatInt(time.Now().Unix(), 10)
	mac := hmac.New(sha256.New, []byte(sign))
	mac.Write([]byte("v0:" + ts + ":" + body))
	req := httptest.NewRequest(http.MethodPost, "/slack/events", strings.NewReader(body))
	req.Header.Set("X-Slack-Request-Timestamp", ts)
	req.Header.Set("X-Slack-Signature", "v0="+hex.EncodeToString(mac.Sum(nil)))
	req.Header.Set("Content-Type", "application/json")
	return req
}

func handler(p Publisher, allow string) *Handler {
	return &Handler{
		SigningSecret:   func(context.Context) (string, error) { return secret, nil },
		Publisher:       p,
		AllowedChannels: ParseAllowlist(allow),
		Log:             slog.New(slog.NewTextHandler(io.Discard, nil)),
	}
}

const mention = `{"token":"x","team_id":"T1","api_app_id":"A1","type":"event_callback","event_id":"Ev1","event_time":1,
"event":{"type":"app_mention","user":"U1","text":"<@UBOT> revenue last month?","ts":"111.222","channel":"C1","event_ts":"111.222"}}`

func TestURLVerification(t *testing.T) {
	rec := httptest.NewRecorder()
	handler(&fakePublisher{}, "").ServeHTTP(rec, signed(t, `{"type":"url_verification","challenge":"abc123","token":"x"}`, secret))
	if rec.Code != http.StatusOK || rec.Body.String() != "abc123" {
		t.Fatalf("got %d %q", rec.Code, rec.Body.String())
	}
}

func TestRejectsBadSignature(t *testing.T) {
	p := &fakePublisher{}
	rec := httptest.NewRecorder()
	handler(p, "").ServeHTTP(rec, signed(t, mention, "wrong-secret"))
	if rec.Code != http.StatusUnauthorized || len(p.queued) != 0 {
		t.Fatalf("got %d, queued %d", rec.Code, len(p.queued))
	}
}

func TestQueuesMentionWithoutTheBotName(t *testing.T) {
	p := &fakePublisher{}
	rec := httptest.NewRecorder()
	handler(p, "").ServeHTTP(rec, signed(t, mention, secret))
	if rec.Code != http.StatusOK || len(p.queued) != 1 {
		t.Fatalf("got %d, queued %d", rec.Code, len(p.queued))
	}
	q := p.queued[0]
	if q.Text != "revenue last month?" || q.ThreadTS != "111.222" || q.Team != "T1" || q.EventID != "Ev1" {
		t.Fatalf("queued %+v", q)
	}
}

func TestIgnoresRetriesAndOtherChannels(t *testing.T) {
	p := &fakePublisher{}
	req := signed(t, mention, secret)
	req.Header.Set("X-Slack-Retry-Num", "1")
	handler(p, "").ServeHTTP(httptest.NewRecorder(), req)
	handler(p, "C999").ServeHTTP(httptest.NewRecorder(), signed(t, mention, secret))
	if len(p.queued) != 0 {
		t.Fatalf("queued %v", p.queued)
	}
}

func TestIgnoresBotMessages(t *testing.T) {
	p := &fakePublisher{}
	bot := strings.Replace(mention, `"user":"U1"`, `"user":"U1","bot_id":"B1"`, 1)
	handler(p, "").ServeHTTP(httptest.NewRecorder(), signed(t, bot, secret))
	if len(p.queued) != 0 {
		t.Fatalf("queued %v", p.queued)
	}
}
