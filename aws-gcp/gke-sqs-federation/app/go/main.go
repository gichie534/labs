// A tiny SQS writer/reader that demonstrates keyless GKE -> AWS authentication via OIDC web
// identity federation.
//
// One image, two modes (MODE=writer|reader):
//
//   - writer: every SEND_INTERVAL it sends a timestamped message to the queue and logs the action.
//   - reader: it long-polls the queue, logs each received message body, then deletes it.
//
// Neither mode contains any AWS credential code. The AWS SDK's default credential chain discovers
// the pod's projected service-account token from the environment that the Deployment sets:
//
//	AWS_ROLE_ARN=arn:aws:iam::<acct>:role/...        (the role to assume)
//	AWS_WEB_IDENTITY_TOKEN_FILE=/var/run/secrets/aws/token   (the projected SA token, aud=sts.amazonaws.com)
//	AWS_REGION=<region>
//
// On the first call the SDK calls sts:AssumeRoleWithWebIdentity with that token and caches the
// short-lived credentials, refreshing them (re-reading the rotated token) before expiry. The
// writer's role may only SendMessage; the reader's role may only Receive/Delete — so the auth
// boundary is enforced by IAM, not by this code.
package main

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/signal"
	"strconv"
	"syscall"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sqs"
)

func main() {
	if err := run(); err != nil {
		log.Fatalf("fatal: %v", err)
	}
}

func run() error {
	mode := os.Getenv("MODE")
	queueURL := os.Getenv("QUEUE_URL")
	if queueURL == "" {
		return fmt.Errorf("QUEUE_URL must be set")
	}

	// Graceful shutdown on SIGTERM/SIGINT so the Deployment rolls cleanly.
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()

	// LoadDefaultConfig wires the web-identity credential provider automatically from the
	// AWS_ROLE_ARN / AWS_WEB_IDENTITY_TOKEN_FILE / AWS_REGION env vars set on the pod.
	cfg, err := config.LoadDefaultConfig(ctx)
	if err != nil {
		return fmt.Errorf("loading AWS config (web identity): %w", err)
	}
	client := sqs.NewFromConfig(cfg)

	switch mode {
	case "writer":
		return runWriter(ctx, client, queueURL)
	case "reader":
		return runReader(ctx, client, queueURL)
	default:
		return fmt.Errorf("MODE must be 'writer' or 'reader', got %q", mode)
	}
}

// runWriter sends a timestamped message every SEND_INTERVAL (default 5s) until the context is
// cancelled, logging each send.
func runWriter(ctx context.Context, client *sqs.Client, queueURL string) error {
	interval := durationEnv("SEND_INTERVAL", 5*time.Second)
	log.Printf("writer starting: queue=%s interval=%s", queueURL, interval)

	ticker := time.NewTicker(interval)
	defer ticker.Stop()

	n := 0
	for {
		select {
		case <-ctx.Done():
			log.Printf("writer stopping after %d message(s)", n)
			return nil
		case <-ticker.C:
			n++
			body := fmt.Sprintf("message #%d sent at %s", n, time.Now().UTC().Format(time.RFC3339Nano))
			out, err := client.SendMessage(ctx, &sqs.SendMessageInput{
				QueueUrl:    aws.String(queueURL),
				MessageBody: aws.String(body),
			})
			if err != nil {
				// Log and keep going — a transient error shouldn't kill the Deployment.
				log.Printf("ERROR send failed: %v", err)
				continue
			}
			log.Printf("SENT body=%q messageId=%s", body, aws.ToString(out.MessageId))
		}
	}
}

// runReader long-polls the queue, logs each message body, and deletes it. Runs until the context is
// cancelled.
func runReader(ctx context.Context, client *sqs.Client, queueURL string) error {
	log.Printf("reader starting: queue=%s", queueURL)

	for {
		select {
		case <-ctx.Done():
			log.Print("reader stopping")
			return nil
		default:
		}

		out, err := client.ReceiveMessage(ctx, &sqs.ReceiveMessageInput{
			QueueUrl:            aws.String(queueURL),
			MaxNumberOfMessages: 10,
			WaitTimeSeconds:     20, // long poll
		})
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			log.Printf("ERROR receive failed: %v", err)
			time.Sleep(2 * time.Second)
			continue
		}

		for _, m := range out.Messages {
			log.Printf("RECEIVED body=%q messageId=%s", aws.ToString(m.Body), aws.ToString(m.MessageId))
			if _, err := client.DeleteMessage(ctx, &sqs.DeleteMessageInput{
				QueueUrl:      aws.String(queueURL),
				ReceiptHandle: m.ReceiptHandle,
			}); err != nil {
				log.Printf("ERROR delete failed: %v", err)
				continue
			}
			log.Printf("DELETED messageId=%s", aws.ToString(m.MessageId))
		}
	}
}

func durationEnv(key string, def time.Duration) time.Duration {
	v := os.Getenv(key)
	if v == "" {
		return def
	}
	// Accept either a plain seconds integer or a Go duration string.
	if secs, err := strconv.Atoi(v); err == nil {
		return time.Duration(secs) * time.Second
	}
	if d, err := time.ParseDuration(v); err == nil {
		return d
	}
	return def
}
