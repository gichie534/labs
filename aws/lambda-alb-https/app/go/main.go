// A minimal "hello world" AWS Lambda function invoked directly by an Application Load Balancer.
//
// The ALB sends each request as an events.ALBTargetGroupRequest and expects an
// events.ALBTargetGroupResponse back (statusCode, statusDescription, headers, body). This is the
// native ALB-target integration — no net/http server and no Lambda Web Adapter. Routing mirrors the
// ECS lab's app: "/" greets, "/healthz" is a health probe, everything else is a 404.
package main

import (
	"context"
	"fmt"
	"net/http"

	"github.com/aws/aws-lambda-go/events"
	"github.com/aws/aws-lambda-go/lambda"
)

func handler(_ context.Context, req events.ALBTargetGroupRequest) (events.ALBTargetGroupResponse, error) {
	switch req.Path {
	case "/":
		return textResponse(http.StatusOK, "Hello, world over HTTPS from AWS Lambda!\n"), nil
	case "/healthz":
		return textResponse(http.StatusOK, "ok\n"), nil
	default:
		return textResponse(http.StatusNotFound, "not found\n"), nil
	}
}

// textResponse builds an ALB target-group response with a plain-text body. statusDescription is
// required by the ALB integration ("<code> <reason>").
func textResponse(status int, body string) events.ALBTargetGroupResponse {
	return events.ALBTargetGroupResponse{
		StatusCode:        status,
		StatusDescription: fmt.Sprintf("%d %s", status, http.StatusText(status)),
		Headers:           map[string]string{"Content-Type": "text/plain; charset=utf-8"},
		Body:              body,
		IsBase64Encoded:   false,
	}
}

func main() {
	lambda.Start(handler)
}
