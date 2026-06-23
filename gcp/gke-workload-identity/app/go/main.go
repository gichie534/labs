// A one-shot reader that demonstrates Workload Identity Federation for GKE.
//
// It runs as a Kubernetes Job under a KSA that has been granted roles/storage.objectViewer on the
// "allowed" bucket and nothing on the "denied" bucket. Using the Google Cloud Storage SDK (which
// auto-discovers the pod's federated KSA credentials — no key, no GSA), it tries to read one object
// from each bucket and prints a human-readable report:
//
//   - success: prints the object's actual contents;
//   - failure: prints the error in a human-readable form (e.g. permission denied).
//
// It exits non-zero only if it cannot form a report at all (e.g. missing config). The expected
// outcome — allowed OK, denied DENIED — is asserted by the lab's `task gke-wi:test` against this
// output, so the Job itself returns 0 on a clean run regardless of the per-bucket results.
package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"time"

	"cloud.google.com/go/storage"
	"google.golang.org/api/googleapi"
)

func main() {
	if err := run(os.Stdout); err != nil {
		log.Fatalf("fatal: %v", err)
	}
}

// run performs both reads and writes the report to w. It returns an error only for setup problems,
// not for an individual bucket read being denied (that is an expected, reported outcome).
func run(w io.Writer) error {
	allowed := os.Getenv("BUCKET_ALLOWED")
	denied := os.Getenv("BUCKET_DENIED")
	object := os.Getenv("OBJECT_NAME")
	if object == "" {
		object = "message.txt"
	}
	if allowed == "" || denied == "" {
		return errors.New("BUCKET_ALLOWED and BUCKET_DENIED must be set")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// The SDK discovers the pod's federated KSA credentials from the environment automatically.
	client, err := storage.NewClient(ctx)
	if err != nil {
		return fmt.Errorf("creating storage client: %w", err)
	}
	defer client.Close()

	fmt.Fprintln(w, "workload-identity read report")
	fmt.Fprintln(w, "=============================")
	reportRead(ctx, w, client, "allowed", allowed, object)
	reportRead(ctx, w, client, "denied", denied, object)
	return nil
}

// reportRead attempts to read gs://<bucket>/<object> and prints a single RESULT line (machine-
// greppable for the test assertions) plus a human-readable detail line.
func reportRead(ctx context.Context, w io.Writer, client *storage.Client, label, bucket, object string) {
	data, err := readObject(ctx, client, bucket, object)
	if err != nil {
		fmt.Fprintf(w, "RESULT access=%s bucket=%s status=DENIED\n", label, bucket)
		fmt.Fprintf(w, "  could not read gs://%s/%s: %s\n", bucket, object, humanizeError(err))
		return
	}
	fmt.Fprintf(w, "RESULT access=%s bucket=%s status=OK\n", label, bucket)
	fmt.Fprintf(w, "  read gs://%s/%s -> %q\n", bucket, object, string(data))
}

func readObject(ctx context.Context, client *storage.Client, bucket, object string) ([]byte, error) {
	r, err := client.Bucket(bucket).Object(object).NewReader(ctx)
	if err != nil {
		return nil, err
	}
	defer r.Close()
	return io.ReadAll(r)
}

// humanizeError turns a Cloud Storage SDK error into a short, readable explanation.
func humanizeError(err error) string {
	var apiErr *googleapi.Error
	if errors.As(err, &apiErr) {
		switch apiErr.Code {
		case 403:
			return "permission denied (403) — the workload's Kubernetes service account has no read access to this bucket"
		case 404:
			return "not found (404) — the bucket or object does not exist"
		default:
			return fmt.Sprintf("API error %d: %s", apiErr.Code, apiErr.Message)
		}
	}
	if errors.Is(err, storage.ErrObjectNotExist) {
		return "object does not exist"
	}
	if errors.Is(err, storage.ErrBucketNotExist) {
		return "bucket does not exist"
	}
	return err.Error()
}
