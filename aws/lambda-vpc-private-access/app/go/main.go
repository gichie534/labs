// A minimal Lambda handler that proves a VPC-attached function can reach a private resource.
//
// It reads TARGET_URL (the private EC2 instance's http://<private-ip>:8080 endpoint) from the
// environment, performs an HTTP GET against it, and returns what it got back. If the function were
// NOT attached to the VPC (or the security-group path were wrong), this GET would time out — so a
// successful response is the demonstration that Lambda has network access to the private instance.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"

	"github.com/aws/aws-lambda-go/lambda"
)

type Response struct {
	OK        bool            `json:"ok"`
	TargetURL string          `json:"target_url"`
	Status    int             `json:"status,omitempty"`
	Backend   json.RawMessage `json:"backend,omitempty"`
	Error     string          `json:"error,omitempty"`
}

func handle(ctx context.Context) (Response, error) {
	target := os.Getenv("TARGET_URL")
	resp := Response{TargetURL: target}

	if target == "" {
		resp.Error = "TARGET_URL is not set"
		return resp, nil
	}

	client := &http.Client{Timeout: 5 * time.Second}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target, nil)
	if err != nil {
		resp.Error = fmt.Sprintf("build request: %v", err)
		return resp, nil
	}

	r, err := client.Do(req)
	if err != nil {
		// The telling failure: no VPC route / SG block => timeout or connection refused.
		resp.Error = fmt.Sprintf("reaching private backend failed: %v", err)
		return resp, nil
	}
	defer r.Body.Close()

	body, err := io.ReadAll(r.Body)
	if err != nil {
		resp.Error = fmt.Sprintf("read body: %v", err)
		return resp, nil
	}

	resp.OK = r.StatusCode == http.StatusOK
	resp.Status = r.StatusCode
	resp.Backend = json.RawMessage(body)
	return resp, nil
}

func main() {
	lambda.Start(handle)
}
