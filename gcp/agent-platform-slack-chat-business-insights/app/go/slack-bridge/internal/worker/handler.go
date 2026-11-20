// Package worker turns a queued Slack question into an agent answer posted in the thread.
//
// It is reached only by Pub/Sub push: the service is private and the push identity is its only invoker, so Cloud
// Run has already authenticated the caller before a request gets here.
package worker

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/agent"
	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/job"
	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/session"
	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/slackfmt"
)

// Agent is the part of agent.Client the worker uses.
type Agent interface {
	EnsureSession(ctx context.Context, userID, sessionID string) error
	Ask(ctx context.Context, userID, sessionID, message string) (agent.Answer, error)
}

// Slack is the part of the Slack Web API the worker uses.
type Slack interface {
	Reply(ctx context.Context, channel, threadTS, text string) error
	React(ctx context.Context, channel, messageTS, emoji string) error
	Unreact(ctx context.Context, channel, messageTS, emoji string) error
}

// SlackFactory returns a Slack client (built lazily from the bot token secret).
type SlackFactory func(ctx context.Context) (Slack, error)

// Handler serves POST /pubsub/push.
type Handler struct {
	Agent   Agent
	Slack   SlackFactory
	Log     *slog.Logger
	Timeout time.Duration
}

// pushEnvelope is the JSON body of a Pub/Sub push request.
type pushEnvelope struct {
	Message struct {
		Data       string            `json:"data"`
		Attributes map[string]string `json:"attributes"`
		MessageID  string            `json:"messageId"`
	} `json:"message"`
	Subscription string `json:"subscription"`
}

const (
	thinkingEmoji = "hourglass_flowing_sand"
	failedEmoji   = "warning"
)

func (h *Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	var env pushEnvelope
	body, err := io.ReadAll(io.LimitReader(r.Body, 1<<20))
	if err == nil {
		err = json.Unmarshal(body, &env)
	}
	if err != nil {
		// A malformed message will never succeed: acknowledge it so Pub/Sub stops redelivering.
		h.Log.Error("dropping undecodable push request", "error", err)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	data, err := base64.StdEncoding.DecodeString(env.Message.Data)
	if err != nil {
		h.Log.Error("dropping message with invalid base64 data", "message_id", env.Message.MessageID, "error", err)
		w.WriteHeader(http.StatusNoContent)
		return
	}
	q, err := job.Unmarshal(data)
	if err != nil {
		h.Log.Error("dropping invalid question", "message_id", env.Message.MessageID, "error", err)
		w.WriteHeader(http.StatusNoContent)
		return
	}

	timeout := h.Timeout
	if timeout == 0 {
		timeout = 9 * time.Minute
	}
	ctx, cancel := context.WithTimeout(r.Context(), timeout)
	defer cancel()

	// Every outcome is acknowledged (2xx). A retry would re-run the agent and post a second answer, which is
	// worse for a Slack user than one error message.
	h.answer(ctx, q, env.Message.MessageID)
	w.WriteHeader(http.StatusNoContent)
}

func (h *Handler) answer(ctx context.Context, q job.Question, messageID string) {
	userID := session.UserID(q.Team, q.User)
	sessionID := session.ID(q.Team, q.Channel, q.ThreadTS)
	log := h.Log.With("message_id", messageID, "event_id", q.EventID, "channel", q.Channel,
		"thread_ts", q.ThreadTS, "agent_user_id", userID, "agent_session_id", sessionID)

	sl, err := h.Slack(ctx)
	if err != nil {
		log.Error("cannot create Slack client", "error", err)
		return
	}
	if err := sl.React(ctx, q.Channel, q.MessageTS, thinkingEmoji); err != nil {
		log.Warn("could not add reaction", "error", err)
	}
	defer func() {
		if err := sl.Unreact(context.WithoutCancel(ctx), q.Channel, q.MessageTS, thinkingEmoji); err != nil {
			log.Warn("could not remove reaction", "error", err)
		}
	}()

	started := time.Now()
	reply, err := h.ask(ctx, userID, sessionID, q.Text)
	elapsed := time.Since(started).Round(time.Millisecond)
	if err != nil {
		log.Error("agent call failed", "error", err, "elapsed", elapsed.String())
		_ = sl.React(ctx, q.Channel, q.MessageTS, failedEmoji)
		reply = fmt.Sprintf("Sorry, I couldn't answer that this time. (ref `%s`)", sessionID)
	} else {
		log.Info("agent answered", "elapsed", elapsed.String())
	}
	if err := sl.Reply(ctx, q.Channel, q.ThreadTS, slackfmt.ToMrkdwn(reply)); err != nil {
		log.Error("could not post the answer to Slack", "error", err)
	}
}

func (h *Handler) ask(ctx context.Context, userID, sessionID, text string) (string, error) {
	if err := h.Agent.EnsureSession(ctx, userID, sessionID); err != nil {
		return "", err
	}
	a, err := h.Agent.Ask(ctx, userID, sessionID, text)
	if err != nil {
		return "", err
	}
	h.Log.Info("agent turn", "agent_session_id", sessionID, "tools", a.Tools, "agent_error", a.Error)
	switch {
	case a.Text != "":
		return a.Text, nil
	case a.Error != "":
		// Typically a guardrail (Model Armor) stopping the turn.
		return "I can't help with that request.", nil
	default:
		return "", fmt.Errorf("agent returned no answer (tools called: %v)", a.Tools)
	}
}
