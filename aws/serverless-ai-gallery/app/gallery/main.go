// The gallery web server — a tiny static-file server that runs as the ECS Fargate container behind
// the HTTPS ALB. It serves the single-page image gallery (index.html + index.js).
//
// The gallery's dynamic behaviour lives in the browser: index.js calls the fetch Lambda's Function
// URL to list images and the ai Lambda's Function URL to generate descriptions, and the "Upload New
// Image" button links to the upload Lambda's Function URL. Those URLs are only known after the
// Lambdas exist, so rather than bake them into the image they are injected at request time from
// environment variables (set on the task definition, wired from the Lambda outputs). That keeps this
// image generic — no rebuild when a URL changes.
package main

import (
	_ "embed"
	"log"
	"net/http"
	"os"
	"strings"
)

//go:embed web/index.html
var indexHTML string

//go:embed web/index.js
var indexJS string

// Placeholders substituted with the Function URLs at request time.
const (
	placeholderUpload = "__UPLOAD_PAGE_URL__"
	placeholderFetch  = "__FETCH_URL__"
	placeholderAI     = "__AI_URL__"
)

func main() {
	port := getenv("PORT", "8080")

	uploadURL := os.Getenv("UPLOAD_PAGE_URL")
	fetchURL := os.Getenv("FETCH_FUNCTION_URL")
	aiURL := os.Getenv("AI_FUNCTION_URL")

	page := strings.ReplaceAll(indexHTML, placeholderUpload, uploadURL)
	script := strings.ReplaceAll(indexJS, placeholderFetch, fetchURL)
	script = strings.ReplaceAll(script, placeholderAI, aiURL)

	mux := http.NewServeMux()

	// Liveness/health probe hit by the ALB target group.
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})

	mux.HandleFunc("/index.js", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/javascript")
		_, _ = w.Write([]byte(script))
	})

	// The gallery is a single page; serve it at the root and treat any other unknown path as the
	// gallery too (SPA-style) so a stray refresh doesn't 404.
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(page))
	})

	log.Printf("gallery listening on :%s", port)
	if err := http.ListenAndServe(":"+port, mux); err != nil {
		log.Fatal(err)
	}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
