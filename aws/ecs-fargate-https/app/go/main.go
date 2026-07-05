// A minimal HTTP server that says hello. It listens on $PORT (default 8080) and serves a
// health-check endpoint at /healthz (what the ALB target group probes). Dependency-free (standard
// library only).
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
)

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/", helloHandler)
	mux.HandleFunc("/healthz", healthHandler)

	addr := ":" + port
	log.Printf("listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatalf("server error: %v", err)
	}
}

func helloHandler(w http.ResponseWriter, r *http.Request) {
	// Only the root path greets; everything else is a 404 so probes to unknown paths don't 200.
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	fmt.Fprintln(w, "Hello, world over HTTPS from ECS Fargate!")
}

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, "ok")
}
