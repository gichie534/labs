// Package secrets reads Secret Manager values at runtime, with a small cache.
//
// Secrets are read by the service's own identity when first needed instead of being injected as env vars. A
// service can then be created before the secret has a version, and rotating a secret only needs a restart.
package secrets

import (
	"context"
	"fmt"
	"sync"
	"time"

	secretmanager "cloud.google.com/go/secretmanager/apiv1"
	"cloud.google.com/go/secretmanager/apiv1/secretmanagerpb"
)

// Source returns the value of a secret version resource name.
type Source interface {
	Get(ctx context.Context, name string) (string, error)
}

// Accessor fetches from the Secret Manager API.
type Accessor struct {
	client *secretmanager.Client
}

// NewAccessor creates a Secret Manager client with Application Default Credentials.
func NewAccessor(ctx context.Context) (*Accessor, error) {
	c, err := secretmanager.NewClient(ctx)
	if err != nil {
		return nil, err
	}
	return &Accessor{client: c}, nil
}

// Get returns the payload of `projects/<p>/secrets/<s>/versions/<v>`.
func (a *Accessor) Get(ctx context.Context, name string) (string, error) {
	resp, err := a.client.AccessSecretVersion(ctx, &secretmanagerpb.AccessSecretVersionRequest{Name: name})
	if err != nil {
		return "", fmt.Errorf("access %s: %w", name, err)
	}
	return string(resp.GetPayload().GetData()), nil
}

// Cached wraps a Source and keeps values for TTL.
type Cached struct {
	Source Source
	TTL    time.Duration
	Now    func() time.Time

	mu     sync.Mutex
	values map[string]entry
}

type entry struct {
	value string
	at    time.Time
}

// Get returns a cached value or fetches it.
func (c *Cached) Get(ctx context.Context, name string) (string, error) {
	now := time.Now
	if c.Now != nil {
		now = c.Now
	}
	c.mu.Lock()
	if e, ok := c.values[name]; ok && now().Sub(e.at) < c.TTL {
		c.mu.Unlock()
		return e.value, nil
	}
	c.mu.Unlock()

	v, err := c.Source.Get(ctx, name)
	if err != nil {
		return "", err
	}
	c.mu.Lock()
	if c.values == nil {
		c.values = map[string]entry{}
	}
	c.values[name] = entry{value: v, at: now()}
	c.mu.Unlock()
	return v, nil
}
