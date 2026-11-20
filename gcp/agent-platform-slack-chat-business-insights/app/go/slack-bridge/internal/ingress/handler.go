// Package ingress is the public Slack Events API endpoint.
//
// It does the minimum inside Slack's 3-second budget: authenticate the request (HMAC signature with the signing
// secret — Cloud Run's IAM check is off for this service, so this IS the authentication), decide whether the
// event is a question for the bot, queue it, and return 200. The slow work happens in the worker.
package ingress

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"strings"

	"github.com/slack-go/slack"
	"github.com/slack-go/slack/slackevents"

	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/job"
	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/slackfmt"
)

const maxBody = 1 << 20

// Publisher queues a question for the worker.
type Publisher interface {
	Publish(ctx context.Context, q job.Question) error
}

// SecretFunc returns the current Slack signing secret.
type SecretFunc func(ctx context.Context) (string, error)

// Handler serves POST /slack/events.
type Handler struct {
	SigningSecret SecretFunc
	Publisher     Publisher
	// AllowedChannels limits where the bot answers. Empty allows every channel the bot is in (and DMs).
	AllowedChannels map[string]bool
	Log             *slog.Logger
}

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody))
	if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if err := h.verify(r.Context(), r.Header, body); err != nil {
		h.Log.Warn("rejected request with an invalid Slack signature", "error", err, "remote", r.RemoteAddr)
		http.Error(w, "invalid signature", http.StatusUnauthorized)
		return
	}

	// Slack retries when it didn't get a 200 in time. The first delivery was already queued (or deliberately
	// dropped), so a retry must not create a second answer.
	if retry := r.Header.Get("X-Slack-Retry-Num"); retry != "" {
		h.Log.Info("ignoring Slack retry", "retry", retry, "reason", r.Header.Get("X-Slack-Retry-Reason"))
		w.WriteHeader(http.StatusOK)
		return
	}

	event, err := slackevents.ParseEvent(json.RawMessage(body), slackevents.OptionNoVerifyToken())
	if err != nil {
		http.Error(w, "bad event", http.StatusBadRequest)
		return
	}

	switch event.Type {
	case slackevents.URLVerification:
		var challenge slackevents.ChallengeResponse
		if err := json.Unmarshal(body, &challenge); err != nil {
			http.Error(w, "bad challenge", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "text/plain")
		_, _ = w.Write([]byte(challenge.Challenge))
		return
	case slackevents.CallbackEvent:
		q, ok := h.question(event)
		if !ok {
			w.WriteHeader(http.StatusOK)
			return
		}
		if cb, ok := event.Data.(*slackevents.EventsAPICallbackEvent); ok {
			q.EventID = cb.EventID
		}
		if err := h.Publisher.Publish(r.Context(), q); err != nil {
			h.Log.Error("failed to queue question", "error", err, "channel", q.Channel)
			// 5xx: Slack will retry the delivery.
			http.Error(w, "queue unavailable", http.StatusServiceUnavailable)
			return
		}
		h.Log.Info("queued question", "event_id", q.EventID, "channel", q.Channel, "thread_ts", q.ThreadTS)
		w.WriteHeader(http.StatusOK)
	default:
		w.WriteHeader(http.StatusOK)
	}
}

func (h *Handler) verify(ctx context.Context, header http.Header, body []byte) error {
	secret, err := h.SigningSecret(ctx)
	if err != nil {
		return err
	}
	v, err := slack.NewSecretsVerifier(header, secret)
	if err != nil {
		return err
	}
	if _, err := v.Write(body); err != nil {
		return err
	}
	return v.Ensure()
}

// question extracts a question for the bot from an app mention or a direct message. Bot messages, edits and
// other subtypes, empty text and channels outside the allowlist are ignored.
func (h *Handler) question(event slackevents.EventsAPIEvent) (job.Question, bool) {
	q := job.Question{Team: event.TeamID}
	switch ev := event.InnerEvent.Data.(type) {
	case *slackevents.AppMentionEvent:
		if ev.BotID != "" {
			return q, false
		}
		q.Channel, q.User, q.Text, q.MessageTS = ev.Channel, ev.User, ev.Text, ev.TimeStamp
		q.ThreadTS = firstNonEmpty(ev.ThreadTimeStamp, ev.TimeStamp)
	case *slackevents.MessageEvent:
		// Only direct messages; channel messages arrive as app_mention.
		if ev.ChannelType != "im" || ev.BotID != "" || ev.SubType != "" {
			return q, false
		}
		q.Channel, q.User, q.Text, q.MessageTS = ev.Channel, ev.User, ev.Text, ev.TimeStamp
		q.ThreadTS = firstNonEmpty(ev.ThreadTimeStamp, ev.TimeStamp)
	default:
		return q, false
	}
	q.Text = slackfmt.StripMentions(q.Text)
	if len(h.AllowedChannels) > 0 && !h.AllowedChannels[q.Channel] && !strings.HasPrefix(q.Channel, "D") {
		h.Log.Info("ignoring message from a channel outside the allowlist", "channel", q.Channel)
		return q, false
	}
	return q, q.Validate() == nil
}

func firstNonEmpty(values ...string) string {
	for _, v := range values {
		if v != "" {
			return v
		}
	}
	return ""
}

// ParseAllowlist turns "C1, C2" into a set.
func ParseAllowlist(csv string) map[string]bool {
	out := map[string]bool{}
	for _, c := range strings.Split(csv, ",") {
		if c = strings.TrimSpace(c); c != "" {
			out[c] = true
		}
	}
	return out
}
