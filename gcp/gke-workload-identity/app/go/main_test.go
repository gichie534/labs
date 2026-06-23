package main

import (
	"errors"
	"strings"
	"testing"

	"cloud.google.com/go/storage"
	"google.golang.org/api/googleapi"
)

func TestHumanizeError(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want string
	}{
		{
			name: "permission denied",
			err:  &googleapi.Error{Code: 403, Message: "forbidden"},
			want: "permission denied (403)",
		},
		{
			name: "not found",
			err:  &googleapi.Error{Code: 404, Message: "no such object"},
			want: "not found (404)",
		},
		{
			name: "object not exist sentinel",
			err:  storage.ErrObjectNotExist,
			want: "object does not exist",
		},
		{
			name: "generic",
			err:  errors.New("boom"),
			want: "boom",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := humanizeError(tc.err)
			if !strings.Contains(got, tc.want) {
				t.Fatalf("humanizeError(%v) = %q, want it to contain %q", tc.err, got, tc.want)
			}
		})
	}
}

func TestRunRequiresBucketEnv(t *testing.T) {
	t.Setenv("BUCKET_ALLOWED", "")
	t.Setenv("BUCKET_DENIED", "")

	var sb strings.Builder
	if err := run(&sb); err == nil {
		t.Fatal("expected an error when bucket env vars are unset, got nil")
	}
}
