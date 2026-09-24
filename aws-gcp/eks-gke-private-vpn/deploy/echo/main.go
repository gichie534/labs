// The thing on the AWS side that answers. Deliberately trivial: a connectivity lab should only ever fail
// for network reasons, so there is no application logic to misconfigure.
//
// It echoes back the CLIENT ADDRESS it saw, which is the interesting output. When a GKE Pod calls this,
// that address is typically a GKE POD address (10.31.x.x), not a GKE node address — because GKE does not
// masquerade Pod traffic to RFC 1918 destinations. Pod addresses come from a subnet SECONDARY range that
// a Cloud Router never advertises on its own, so this response is direct evidence that the Pod range is
// being advertised over BGP and that AWS has a route back to it.
package main

import (
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
)

func main() {
	const addr = ":8080"

	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		client, _, err := net.SplitHostPort(r.RemoteAddr)
		if err != nil {
			client = r.RemoteAddr
		}

		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprintf(w,
			"reached-eks-over-vpn\n"+
				"served_by_pod=%s\n"+
				"served_by_node_ip=%s\n"+
				"pod_ip=%s\n"+
				"client_address_as_seen_by_aws=%s\n",
			env("POD_NAME"), env("NODE_IP"), env("POD_IP"), client)

		log.Printf("%s %s %s", client, r.Method, r.URL.Path)
	})

	log.Printf("listening on %s", addr)
	log.Fatal(http.ListenAndServe(addr, nil))
}

func env(key string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return "unknown"
}
