// Runs in GKE and calls the EKS echo server across the VPN.
//
// It asserts two things, in order, because they fail differently:
//
//  1. The load balancer hostname resolves to a PRIVATE address. An AWS internal load balancer is
//     published in PUBLIC DNS but resolves to a private address, so an ordinary cluster resolver is
//     enough — no private DNS zone, no /etc/hosts entry. A public address here would mean the wrong kind
//     of load balancer was created, and the request might well succeed over the internet, which would be
//     a false pass.
//
//  2. The request actually completes. It retries, because BGP can still be settling shortly after
//     `task up`.
//
// The diagnosis on failure distinguishes a HANG from a REFUSAL, since they point at different causes.
package main

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"
)

const (
	attempts = 10
	interval = 10 * time.Second
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "\nFAIL: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	target := os.Getenv("ECHO_URL")
	if target == "" {
		return fmt.Errorf("ECHO_URL must be set")
	}

	host, err := hostOf(target)
	if err != nil {
		return err
	}

	fmt.Printf("this pod's address      : %s\n", os.Getenv("POD_IP"))
	fmt.Printf("target                  : %s\n", target)

	addrs, err := net.LookupIP(host)
	if err != nil {
		return fmt.Errorf("could not resolve %s: %w", host, err)
	}
	resolved := addrs[0]
	fmt.Printf("resolved to             : %s\n", resolved)

	if !resolved.IsPrivate() {
		return fmt.Errorf("%s resolved to %s, which is not a private address.\n"+
			"      An INTERNAL load balancer must resolve to a private address; a public one would mean\n"+
			"      this traffic could be crossing the internet rather than the VPN", host, resolved)
	}
	fmt.Println("                          (private — so this crosses the VPN, not the internet)")
	fmt.Println()

	client := &http.Client{Timeout: 10 * time.Second}
	var last error

	for attempt := 1; attempt <= attempts; attempt++ {
		body, err := fetch(client, target)
		if err != nil {
			last = err
			fmt.Printf("attempt %d: %v\n", attempt, err)
			time.Sleep(interval)
			continue
		}

		fmt.Printf("attempt %d: HTTP 200\n%s\n", attempt, body)
		report(body)
		return nil
	}

	fmt.Println()
	fmt.Println("Never got a response.")
	fmt.Println("  A HANG (timeout) usually means ROUTING: check that the GKE Pod range is advertised")
	fmt.Println("  over BGP and that AWS route propagation is enabled on the private route tables.")
	fmt.Println("  A REFUSAL usually means the load balancer's loadBalancerSourceRanges.")
	fmt.Println("  Either way, run `task vpn-status` first — tunnels can be ESTABLISHED while BGP is not.")
	return fmt.Errorf("last error: %w", last)
}

func hostOf(rawURL string) (string, error) {
	trimmed := strings.TrimPrefix(strings.TrimPrefix(rawURL, "http://"), "https://")
	trimmed = strings.SplitN(trimmed, "/", 2)[0]
	host, _, err := net.SplitHostPort(trimmed)
	if err != nil {
		return trimmed, nil // no port present
	}
	return host, nil
}

func fetch(client *http.Client, url string) (string, error) {
	resp, err := client.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return string(body), nil
}

// report explains what the client address the server saw actually tells us.
func report(body string) {
	bar := strings.Repeat("=", 70)
	fmt.Println(bar)
	fmt.Println("  SUCCESS — a GKE Pod reached an EKS Pod over private addressing only.")

	addr := ""
	for _, line := range strings.Split(body, "\n") {
		if rest, ok := strings.CutPrefix(line, "client_address_as_seen_by_aws="); ok {
			addr = strings.TrimSpace(rest)
		}
	}
	if addr != "" {
		fmt.Printf("  AWS saw the client as %s.\n", addr)
		if strings.HasPrefix(addr, "10.31.") {
			fmt.Println("  That is a GKE POD address, which routes only because the Pod secondary range is")
			fmt.Println("  advertised over BGP. Remove that advertisement and this request hangs instead")
			fmt.Println("  of failing.")
		} else {
			fmt.Println("  That is not in the Pod range, so this traffic was masqueraded to the node address")
			fmt.Println("  before leaving GKE. Also fine — the node subnet is advertised automatically.")
			fmt.Println("  Advertising both is what makes the path work either way.")
		}
	}
	fmt.Println(bar)
}
