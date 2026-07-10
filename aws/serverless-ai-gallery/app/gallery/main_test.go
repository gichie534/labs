package main

import (
	"strings"
	"testing"
)

// The embedded index.js must carry the placeholders the server substitutes at request time; a typo
// in either the asset or a constant would silently ship un-wired URLs to the browser.
func TestIndexJSHasURLPlaceholders(t *testing.T) {
	for _, ph := range []string{placeholderFetch, placeholderAI, placeholderUpload} {
		if !strings.Contains(indexJS, ph) {
			t.Fatalf("index.js is missing the %q placeholder", ph)
		}
	}
}
