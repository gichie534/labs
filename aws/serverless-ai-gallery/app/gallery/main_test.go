package main

import (
	"strings"
	"testing"
)

// The embedded assets must carry the placeholders the server substitutes at request time; a typo in
// either the asset or the constant would silently ship un-wired URLs to the browser.
func TestIndexHTMLHasUploadPlaceholder(t *testing.T) {
	if !strings.Contains(indexHTML, placeholderUpload) {
		t.Fatalf("index.html is missing the %q placeholder", placeholderUpload)
	}
}

func TestIndexJSHasURLPlaceholders(t *testing.T) {
	for _, ph := range []string{placeholderFetch, placeholderAI} {
		if !strings.Contains(indexJS, ph) {
			t.Fatalf("index.js is missing the %q placeholder", ph)
		}
	}
}
