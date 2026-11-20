// Command slack-bridge connects a Slack app to the business-insights agent on Agent Runtime.
//
// One image, two Cloud Run services, selected by MODE:
//
//	MODE=ingress  public. POST /slack/events: verify Slack's signature, queue the question on Pub/Sub, return 200.
//	MODE=worker   private. POST /pubsub/push: call the agent (one session per Slack thread), reply in the thread.
//
// Splitting them keeps each identity small: the public service can't call the agent or read the bot token, and the
// service that can is not reachable from the internet.
package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"cloud.google.com/go/pubsub/v2"
	"github.com/slack-go/slack"
	"golang.org/x/oauth2/google"

	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/agent"
	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/ingress"
	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/job"
	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/secrets"
	"github.com/gichie534/labs/gcp/agent-platform-slack-chat-business-insights/app/go/slack-bridge/internal/worker"
)

func main() {
	// Cloud Logging parses JSON lines on stdout; "severity" drives log levels and the worker-errors alert.
	log := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{ReplaceAttr: cloudLoggingKeys}))
	if err := run(log); err != nil {
		log.Error("exiting", "error", err)
		os.Exit(1)
	}
}

func run(log *slog.Logger) error {
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, os.Interrupt)
	defer stop()

	sec, err := secrets.NewAccessor(ctx)
	if err != nil {
		return fmt.Errorf("secret manager: %w", err)
	}
	cache := &secrets.Cached{Source: sec, TTL: 10 * time.Minute}

	mux := http.NewServeMux()
	// Not /healthz: Cloud Run reserves paths ending in "z" and answers them itself with a 404.
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte("ok")) })

	switch mode := os.Getenv("MODE"); mode {
	case "ingress":
		pub, closeFn, err := newPublisher(ctx, mustEnv("GOOGLE_CLOUD_PROJECT"), mustEnv("PUBSUB_TOPIC"))
		if err != nil {
			return err
		}
		defer closeFn()
		secretName := mustEnv("SLACK_SIGNING_SECRET_SECRET")
		mux.Handle("POST /slack/events", &ingress.Handler{
			SigningSecret:   func(ctx context.Context) (string, error) { return cache.Get(ctx, secretName) },
			Publisher:       pub,
			AllowedChannels: ingress.ParseAllowlist(os.Getenv("SLACK_ALLOWED_CHANNELS")),
			Log:             log,
		})
	case "worker":
		httpClient, err := google.DefaultClient(ctx, "https://www.googleapis.com/auth/cloud-platform")
		if err != nil {
			return fmt.Errorf("google credentials: %w", err)
		}
		httpClient.Timeout = 0 // streamQuery responses stream for as long as the agent works; the request context bounds them
		tokenSecret := mustEnv("SLACK_BOT_TOKEN_SECRET")
		mux.Handle("POST /pubsub/push", &worker.Handler{
			Agent: agent.New(httpClient, mustEnv("AGENT_LOCATION"), mustEnv("AGENT_RESOURCE_NAME")),
			Slack: func(ctx context.Context) (worker.Slack, error) {
				token, err := cache.Get(ctx, tokenSecret)
				if err != nil {
					return nil, err
				}
				return worker.SlackAPI{Client: slack.New(token)}, nil
			},
			Log: log,
		})
	default:
		return fmt.Errorf("MODE must be ingress or worker, got %q", mode)
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}
	srv := &http.Server{Addr: ":" + port, Handler: mux, ReadHeaderTimeout: 10 * time.Second}
	go func() {
		<-ctx.Done()
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		_ = srv.Shutdown(shutdown)
	}()
	log.Info("listening", "mode", os.Getenv("MODE"), "port", port)
	if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		return err
	}
	return nil
}

// topicPublisher publishes questions to Pub/Sub and waits for the server ack (well within Slack's 3 s).
type topicPublisher struct {
	p *pubsub.Publisher
}

func newPublisher(ctx context.Context, project, topic string) (*topicPublisher, func(), error) {
	client, err := pubsub.NewClient(ctx, project)
	if err != nil {
		return nil, nil, fmt.Errorf("pubsub: %w", err)
	}
	p := client.Publisher(topic)
	return &topicPublisher{p: p}, func() { p.Stop(); _ = client.Close() }, nil
}

func (t *topicPublisher) Publish(ctx context.Context, q job.Question) error {
	data, err := q.Marshal()
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	_, err = t.p.Publish(ctx, &pubsub.Message{
		Data:       data,
		Attributes: map[string]string{"channel": q.Channel, "event_id": q.EventID},
	}).Get(ctx)
	return err
}

func mustEnv(key string) string {
	v := os.Getenv(key)
	if v == "" {
		fmt.Fprintf(os.Stderr, "missing required environment variable %s\n", key)
		os.Exit(2)
	}
	return v
}

// cloudLoggingKeys renames slog's keys to the ones Cloud Logging understands.
func cloudLoggingKeys(groups []string, a slog.Attr) slog.Attr {
	if len(groups) > 0 {
		return a
	}
	switch a.Key {
	case slog.LevelKey:
		a.Key = "severity"
		if lvl, ok := a.Value.Any().(slog.Level); ok && lvl == slog.LevelWarn {
			a.Value = slog.StringValue("WARNING")
		}
	case slog.MessageKey:
		a.Key = "message"
	case slog.TimeKey:
		a.Key = "time"
	}
	return a
}
