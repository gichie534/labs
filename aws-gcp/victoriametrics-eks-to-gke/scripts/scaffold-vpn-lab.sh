#!/usr/bin/env bash
# Scaffold aws-gcp/eks-gke-private-vpn — a lab about ONE thing: private EKS <-> GKE connectivity.
#
# This lab (victoriametrics-eks-to-gke) proved the connectivity slice as a side effect of needing it.
# That slice is worth its own lab, and this script extracts it: it COPIES the seven Terragrunt units
# that already work rather than reimplementing them, then writes a fresh Taskfile, README, ADR and a
# connectivity test that has no observability in it at all.
#
# Run it from this lab's directory:
#   ./scripts/scaffold-vpn-lab.sh
#
# The generated lab is self-contained and has no dependency on this one afterwards.
set -euo pipefail

SRC_LAB="$(cd "$(dirname "$0")/.." && pwd)"
LABS_ROOT="$(cd "$SRC_LAB/../.." && pwd)"
DEST="$LABS_ROOT/aws-gcp/eks-gke-private-vpn"

OLD_LAB_NAME="victoriametrics-eks-to-gke"
NEW_LAB_NAME="eks-gke-private-vpn"
OLD_PREFIX="vmmig"
NEW_PREFIX="xcvpn"

if [ -e "$DEST" ]; then
  echo "ERROR: $DEST already exists — refusing to overwrite." >&2
  exit 1
fi

echo "==> scaffolding $DEST"
mkdir -p "$DEST/infra/aws" "$DEST/infra/gcp" "$DEST/deploy" "$DEST/docs/adr"

# --- 1. Version pins, copied verbatim ---------------------------------------------------------------
cp "$SRC_LAB/.terraform-version" "$SRC_LAB/.terragrunt-version" "$DEST/"

# --- 2. The infra units that already work -----------------------------------------------------------
# Copied, not rewritten: these are the configurations this lab exercised end to end. Only the lab name
# and resource prefix change.
for unit in aws/network aws/cluster aws/vpn gcp/network gcp/cluster gcp/vpn-gateway gcp/vpn-tunnels; do
  mkdir -p "$DEST/infra/$unit"
  sed -e "s/$OLD_LAB_NAME/$NEW_LAB_NAME/g" \
      -e "s/$OLD_PREFIX/$NEW_PREFIX/g" \
      "$SRC_LAB/infra/$unit/terragrunt.hcl" > "$DEST/infra/$unit/terragrunt.hcl"
  echo "    copied infra/$unit"
done

# --- 3. root.hcl ------------------------------------------------------------------------------------
sed -e "s/$OLD_LAB_NAME/$NEW_LAB_NAME/g" \
    -e "s/$OLD_PREFIX/$NEW_PREFIX/g" \
    "$SRC_LAB/root.hcl" > "$DEST/root.hcl"

# --- 4. Rewrite the prose that describes the OTHER lab ----------------------------------------------
# The copied units carry observability-sized nodes, migration-flavoured role tags, and comments about
# VictoriaMetrics. The HCL is exactly what we want; the prose is about a different lab.
#
# Rewritten with Python rather than sed because these are multi-line replacements, and the script FAILS
# if an expected passage is missing — a generated lab carrying comments about a stack it does not run is
# worse than one that refused to generate.
python3 - "$DEST" <<'PYEOF'
import pathlib
import sys

dest = pathlib.Path(sys.argv[1])

AWS_HEADER = '''# The EKS cluster: one end of the private cross-cloud path. It runs a trivial echo server and nothing
# else — a connectivity lab should only ever fail for network reasons.
#
# Nodes run in the private subnets, so the addresses the GKE side reaches over the VPN come from the
# VPC's own private ranges (the VPC CNI gives pods real VPC addresses).
#
# LAB TRADEOFF: endpoint_public_access_cidrs is 0.0.0.0/0 so your kubectl reaches the API server from
# anywhere. Only the CONTROL PLANE is public — the workload path between the clusters has no public
# listener at all. Narrow this for anything longer-lived.
# See docs/adr/0001-cross-cloud-vpn-topology.md.
'''

GCP_HEADER = '''# The GKE Autopilot cluster: the other end of the private cross-cloud path, and where the connectivity
# test runs. It reaches the EKS echo server over the VPN using private addressing only.
#
# LAB TRADEOFF: master_authorized_networks is 0.0.0.0/0 so your kubectl reaches the control plane from
# anywhere. Only the CONTROL PLANE is public; the workload path is private-only.
'''

NODE_COMMENT_OLD = '''  # A full VictoriaMetrics k8s stack + VictoriaLogs + its collector + the load generators + the seed
  # job share these nodes. t3.medium fits but leaves no headroom once avalanche asks for its 512Mi,
  # and a pod stuck Pending is a slow way to discover that.
'''
NODE_COMMENT_NEW = '''  # An echo server and nothing else, so the nodes can be small.
'''


def fail(msg: str) -> None:
    sys.exit(f"ERROR: {msg}\n       The source lab's wording changed; update scaffold-vpn-lab.sh.")


def replace_header(path: pathlib.Path, header: str) -> str:
    text = path.read_text()
    marker = 'include "root" {'
    idx = text.find(marker)
    if idx == -1:
        fail(f'{path}: no `include "root"` block found')
    return header + "\n" + text[idx:]


# --- aws/cluster ---
aws = dest / "infra/aws/cluster/terragrunt.hcl"
text = replace_header(aws, AWS_HEADER)
if NODE_COMMENT_OLD not in text:
    fail(f"{aws}: the node-sizing comment was not found")
text = text.replace(NODE_COMMENT_OLD, NODE_COMMENT_NEW)
if '"t3.large"' not in text:
    fail(f"{aws}: expected a t3.large default to shrink")
text = text.replace('"t3.large"', '"t3.small"')
if 'Role = "migration-source"' not in text:
    fail(f"{aws}: expected the migration-source role tag")
text = text.replace('Role = "migration-source"', 'Role = "vpn-connectivity"')
aws.write_text(text)

# --- gcp/cluster ---
gcp = dest / "infra/gcp/cluster/terragrunt.hcl"
text = replace_header(gcp, GCP_HEADER)
if 'role = "migration-target"' not in text:
    fail(f"{gcp}: expected the migration-target role label")
text = text.replace('role = "migration-target"', 'role = "vpn-connectivity"')
gcp.write_text(text)

# --- Remaining prose that names the observability stack ---
# Each entry is (relative path, exact old text, new text). Every one must match, so a reworded source
# lab breaks the generator instead of quietly producing stale comments.
REWRITES = [
    (
        "root.hcl",
        "# A CROSS-CLOUD lab: an EKS cluster (AWS, migration SOURCE) and a GKE Autopilot cluster (GCP,\n"
        "# migration TARGET), joined by a BGP-routed IPsec VPN so the migration runs entirely over private\n"
        "# addressing.",
        "# A CROSS-CLOUD lab: an EKS cluster (AWS) and a GKE Autopilot cluster (GCP), joined by a\n"
        "# BGP-routed IPsec VPN so workloads in one can reach workloads in the other over private\n"
        "# addressing only.",
    ),
    (
        "root.hcl",
        "  # --- GCP (target: GKE + VictoriaMetrics/VictoriaLogs destination) ---",
        "  # --- GCP (the GKE end of the private path) ---",
    ),
    (
        "root.hcl",
        "  # --- AWS (source: EKS + VictoriaMetrics/VictoriaLogs origin) ---",
        "  # --- AWS (the EKS end of the private path) ---",
    ),
    (
        "infra/aws/network/terragrunt.hcl",
        "load balancers that expose VictoriaMetrics/VictoriaLogs to the",
        "load balancer that exposes the echo server to the",
    ),
    (
        "infra/gcp/network/terragrunt.hcl",
        "# reach the internet to pull the VictoriaMetrics/Grafana images.",
        "# reach the internet to pull container images.",
    ),
]

for rel, old, new in REWRITES:
    path = dest / rel
    text = path.read_text()
    if old not in text:
        fail(f"{path}: expected passage not found:\n         {old.splitlines()[0]}")
    path.write_text(text.replace(old, new))

print("    rewrote the cluster units' prose for a connectivity lab")
print(f"    rewrote {len(REWRITES)} further passages that named the observability stack")
PYEOF

# --- 5. .env.example --------------------------------------------------------------------------------
cat > "$DEST/.env.example" <<'ENVEOF'
# Copy to `.env` and fill in. The Taskfile loads `.env` automatically (dotenv); `.env` is gitignored.
#
# Format: KEY=value (no `export`, no spaces around `=`).

# --- Core GCP ---
GCP_PROJECT=my-project
GCP_REGION=us-central1

# --- Core AWS ---
# Credentials come from your normal AWS CLI environment (profile / SSO / env vars); only the region
# is set here.
AWS_REGION=us-east-1

# --- Terraform state ---
# One GCS bucket holds state for BOTH the aws/* and gcp/* units. `task init-state` creates it.
TF_STATE_BUCKET=my-tf-state-bucket

# --- Operator access ---
# Both Kubernetes API servers keep a public endpoint so kubectl works from anywhere. That is a LAB
# TRADEOFF and it is the asymmetry the lab is about: the control planes are public, the workload path
# between the clusters is private-only. Narrow endpoint_public_access_cidrs and
# master_authorized_networks for anything longer-lived.
ENVEOF

# --- 6. .gitignore ----------------------------------------------------------------------------------
cat > "$DEST/.gitignore" <<'GITEOF'
# Nothing lab-specific to ignore yet; `.env` is covered by the repo-root .gitignore.
GITEOF

# --- 7. The connectivity test -----------------------------------------------------------------------
# An echo server on EKS behind an INTERNAL load balancer, and a probe on GKE that calls it. Both are Go
# programs delivered as ConfigMaps and run with `go run`, the same no-registry approach the migration lab
# uses — which matters more here, because a connectivity lab that needed a working image pull in two
# clouds before it could test connectivity would have the dependency backwards.
mkdir -p "$DEST/deploy/echo" "$DEST/deploy/probe"

cat > "$DEST/deploy/echo/go.mod" <<'EOF'
module github.com/gichie534/labs/aws-gcp/eks-gke-private-vpn/deploy/echo

go 1.24
EOF

cat > "$DEST/deploy/echo/main.go" <<'EOF'
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
EOF

cat > "$DEST/deploy/probe/go.mod" <<'EOF'
module github.com/gichie534/labs/aws-gcp/eks-gke-private-vpn/deploy/probe

go 1.24
EOF

cat > "$DEST/deploy/probe/main.go" <<'EOF'
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
EOF

cat > "$DEST/deploy/echo-server.yaml" <<'ECHOEOF'
# The EKS side of the test: an echo server reachable only on a private address.
#
# The Go source is delivered separately, as the `echo-src` ConfigMap built by `task deploy` from
# deploy/echo/ — so there is no image to build and no registry to authenticate against.
---
apiVersion: v1
kind: Namespace
metadata:
  name: vpn-test
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo-server
  namespace: vpn-test
  labels:
    app: echo-server
spec:
  replicas: 2
  selector:
    matchLabels:
      app: echo-server
  template:
    metadata:
      labels:
        app: echo-server
    spec:
      containers:
        - name: echo
          image: golang:1.24-alpine
          workingDir: /app
          command: ["go", "run", "."]
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: NODE_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.hostIP
            # Go toolchain state, all under the writable emptyDir (the source mount is read-only).
            - name: HOME
              value: /tmp
            - name: GOCACHE
              value: /tmp/go-build
            - name: GOMODCACHE
              value: /tmp/gomodcache
            - name: GOPATH
              value: /tmp/gopath
            - name: GOFLAGS
              value: -buildvcs=false
            - name: CGO_ENABLED
              value: "0"
          readinessProbe:
            httpGet:
              path: /
              port: http
            # `go run` compiles first, so readiness is deliberately patient.
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 30
          volumeMounts:
            - name: src
              mountPath: /app
              readOnly: true
            - name: gocache
              mountPath: /tmp
          resources:
            requests:
              cpu: 500m
              memory: 512Mi
            limits:
              cpu: 500m
              memory: 512Mi
      volumes:
        - name: src
          configMap:
            name: echo-src
        - name: gocache
          emptyDir: {}
---
# INTERNAL load balancer: a stable private address, with no public listener anywhere.
apiVersion: v1
kind: Service
metadata:
  name: echo-private-lb
  namespace: vpn-test
  annotations:
    service.beta.kubernetes.io/aws-load-balancer-internal: "true"
    service.beta.kubernetes.io/aws-load-balancer-scheme: internal
spec:
  type: LoadBalancer
  # Only the GKE node and Pod ranges may connect. The Pod range must be here: without it the requests
  # arrive from an address this list does not cover and are dropped by the load balancer's security
  # group — which looks exactly like a broken VPN.
  loadBalancerSourceRanges:
    - 10.30.0.0/20
    - 10.31.0.0/16
  selector:
    app: echo-server
  ports:
    - name: http
      port: 8080
      targetPort: http
ECHOEOF

cat > "$DEST/deploy/connectivity-test-job.yaml" <<'TESTEOF'
# Runs in GKE and calls the EKS echo server across the VPN. `__ECHO_HOST__` is substituted by
# `task test` with the AWS internal load balancer hostname.
#
# The Go source arrives as the `probe-src` ConfigMap, built by `task test` from deploy/probe/.
apiVersion: batch/v1
kind: Job
metadata:
  name: connectivity-test
  namespace: vpn-test
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: probe
          image: golang:1.24-alpine
          workingDir: /app
          command: ["go", "run", "."]
          env:
            - name: ECHO_URL
              value: "http://__ECHO_HOST__:8080/"
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
            - name: HOME
              value: /tmp
            - name: GOCACHE
              value: /tmp/go-build
            - name: GOMODCACHE
              value: /tmp/gomodcache
            - name: GOPATH
              value: /tmp/gopath
            - name: GOFLAGS
              value: -buildvcs=false
            - name: CGO_ENABLED
              value: "0"
          volumeMounts:
            - name: src
              mountPath: /app
              readOnly: true
            - name: gocache
              mountPath: /tmp
          resources:
            requests:
              cpu: 1000m
              memory: 1Gi
            limits:
              cpu: 1000m
              memory: 1Gi
      volumes:
        - name: src
          configMap:
            name: probe-src
        - name: gocache
          emptyDir: {}
TESTEOF

# --- 8. Taskfile ------------------------------------------------------------------------------------
cat > "$DEST/Taskfile.yml" <<'TASKEOF'
version: '3'

dotenv: ['.env']

# Lifecycle for the aws-gcp/eks-gke-private-vpn lab.
#
# One question: can a Pod in GKE reach a Pod in EKS over private addressing only? It stands up both
# clusters, joins the two VPCs with a BGP-routed IPsec VPN, and proves the path with an echo server
# behind an INTERNAL load balancer.
#
# Only init-state, up and deploy create cloud resources. fmt/validate/plan/vpn-status are cost-free.
#
# COST: an EKS control plane, a NAT gateway, 2 small EC2 nodes, a GKE Autopilot cluster, Cloud NAT, one
# internal load balancer, two AWS VPN connections and two Cloud VPN tunnels. VPN connections and
# tunnels bill from creation whether or not traffic flows.

vars:
  SOURCE_CLUSTER: xcvpn-source
  TARGET_CLUSTER: xcvpn-target
  AWS_CTX: xcvpn-aws
  GCP_CTX: xcvpn-gcp
  NS: vpn-test

tasks:
  default:
    cmds: [task --list]
    silent: true

  init-env:
    desc: Create a local .env from the template (no-op if .env already exists)
    cmds:
      - |
        if [ -f .env ]; then
          echo ".env already exists — leaving it untouched."
        else
          cp .env.example .env
          echo "Created .env from .env.example — fill in your values."
        fi

  init-state:
    desc: Create the GCS bucket for Terraform/Terragrunt remote state (idempotent; run once before `up`)
    cmds:
      - |
        : "${GCP_PROJECT:?set GCP_PROJECT=<project id>}"
        : "${TF_STATE_BUCKET:?set TF_STATE_BUCKET=<bucket name (no gs:// prefix)>}"
        LOCATION="${GCP_REGION:-us-central1}"
        if gcloud storage buckets describe "gs://$TF_STATE_BUCKET" --project "$GCP_PROJECT" >/dev/null 2>&1; then
          echo "Bucket gs://$TF_STATE_BUCKET already exists — nothing to do."
        else
          gcloud storage buckets create "gs://$TF_STATE_BUCKET" \
            --project "$GCP_PROJECT" --location "$LOCATION" \
            --uniform-bucket-level-access --public-access-prevention
        fi
        gcloud storage buckets update "gs://$TF_STATE_BUCKET" --versioning

  fmt:
    desc: Format Terragrunt HCL
    cmds: [terragrunt hcl format]

  validate:
    desc: Validate every infra unit (cost-free)
    dir: infra
    cmds: [terragrunt run --all validate]

  lint:
    desc: Lint Terraform/Terragrunt (cost-free)
    cmds: [tflint --recursive]

  plan:
    desc: Plan all infra units (cost-free)
    dir: infra
    cmds: [terragrunt run --all plan]

  up:
    desc: 'Provision both VPCs, both clusters, and the three-phase cross-cloud VPN (creates cloud resources)'
    dir: infra
    cmds:
      - terragrunt run --all apply --non-interactive
      - |
        echo ""
        echo "Infra is up, but the VPN is not necessarily ready: tunnels take a couple of minutes to"
        echo "establish and BGP a little longer to settle. Run 'task vpn-status' next."

  vpn-status:
    desc: 'Show whether both tunnels are up and BGP has exchanged routes (cost-free; run before `test`)'
    cmds:
      - |
        : "${GCP_PROJECT:?set GCP_PROJECT}"
        REGION="${GCP_REGION:-us-central1}"
        ROUTER="$(cd infra/gcp/vpn-tunnels && terragrunt output -raw router_name)"

        echo "=== Cloud VPN tunnels (GCP side) ==="
        gcloud compute vpn-tunnels list --project "$GCP_PROJECT" \
          --filter="region:($REGION)" --format="table(name, status, detailedStatus)"

        echo ""
        echo "=== BGP sessions and routes learned FROM AWS ==="
        # The real test: a tunnel can sit ESTABLISHED while BGP never comes up (an ASN mismatch does
        # exactly that), and then nothing routes even though everything looks connected.
        gcloud compute routers get-status "$ROUTER" --project "$GCP_PROJECT" --region "$REGION" \
          --format="yaml(result.bgpPeerStatus[].name, result.bgpPeerStatus[].state, result.bgpPeerStatus[].status, result.bgpPeerStatus[].advertisedRoutes[].destRange, result.bgpPeerStatus[].learnedRoutes[].destRange)"

        echo ""
        echo "Expect: both tunnels ESTABLISHED, both peers state=Established, learned routes covering"
        echo "10.20.0.0/16 (the AWS VPC), and ADVERTISED routes including 10.31.0.0/16 (the GKE Pod"
        echo "range) — that last one is what lets an EKS node reply to a GKE Pod."
        echo ""
        echo "Note: the SECOND tunnel of each AWS VPN connection stays DOWN by design. An HA VPN"
        echo "interface pairs with one connection, so only tunnel 1 of each is used."

  kubeconfig:
    desc: Add kubeconfig entries for BOTH clusters under stable context names
    cmds:
      - |
        : "${AWS_REGION:?set AWS_REGION}"
        aws eks update-kubeconfig --name {{.SOURCE_CLUSTER}} --region "$AWS_REGION" --alias {{.AWS_CTX}}
      - |
        : "${GCP_PROJECT:?set GCP_PROJECT}"
        REGION="${GCP_REGION:-us-central1}"
        gcloud container clusters get-credentials {{.TARGET_CLUSTER}} --region "$REGION" --project "$GCP_PROJECT"
        RAW="gke_${GCP_PROJECT}_${REGION}_{{.TARGET_CLUSTER}}"
        kubectl config delete-context {{.GCP_CTX}} >/dev/null 2>&1 || true
        kubectl config rename-context "$RAW" {{.GCP_CTX}}
      - 'echo "Contexts ready: {{.AWS_CTX}} (EKS) and {{.GCP_CTX}} (GKE)."'

  build:
    desc: 'Compile both Go programs (cost-free) — catches a type error before any cloud resource is touched'
    cmds:
      - |
        for d in deploy/echo deploy/probe; do
          echo "==> $d"
          ( cd "$d" && gofmt -l . | tee /dev/stderr | (! grep -q .) && go build ./... && go vet ./... )
        done

  deploy:
    desc: 'Deploy the echo server on EKS behind an internal load balancer'
    deps: [build]
    cmds:
      - kubectl --context {{.AWS_CTX}} apply -f deploy/echo-server.yaml
      # The Go source travels as a ConfigMap and is compiled in-pod by `go run`, so this lab needs no
      # container registry in either cloud — which matters here more than usual: a connectivity lab that
      # required a working cross-cloud image pull before it could test connectivity would have the
      # dependency backwards.
      - |
        kubectl --context {{.AWS_CTX}} -n {{.NS}} create configmap echo-src \
          --from-file=deploy/echo/ --dry-run=client -o yaml \
        | kubectl --context {{.AWS_CTX}} apply -f -
      - kubectl --context {{.AWS_CTX}} -n {{.NS}} rollout restart deployment/echo-server
      - kubectl --context {{.AWS_CTX}} -n {{.NS}} rollout status deployment/echo-server --timeout=5m
      - |
        echo "Waiting for the internal load balancer to get an address..."
        for i in $(seq 1 40); do
          HOST="$(kubectl --context {{.AWS_CTX}} -n {{.NS}} get svc echo-private-lb \
            -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
          if [ -n "$HOST" ]; then echo "  echo server: $HOST:8080 (private address only)"; exit 0; fi
          echo "  not ready yet ($i/40) — retrying in 15s"; sleep 15
        done
        echo "ERROR: the load balancer never got an address." >&2
        echo "Most common cause: the private subnets are missing the kubernetes.io/role/internal-elb" >&2
        echo "or kubernetes.io/cluster/{{.SOURCE_CLUSTER}} tag, so subnet discovery found nothing." >&2
        exit 1

  test:
    desc: 'Prove it: a Job in GKE calls the EKS echo server over private addressing only'
    deps: [build]
    cmds:
      - kubectl --context {{.GCP_CTX}} create namespace {{.NS}} --dry-run=client -o yaml | kubectl --context {{.GCP_CTX}} apply -f -
      - |
        kubectl --context {{.GCP_CTX}} -n {{.NS}} create configmap probe-src \
          --from-file=deploy/probe/ --dry-run=client -o yaml \
        | kubectl --context {{.GCP_CTX}} apply -f -
      - |
        HOST="$(kubectl --context {{.AWS_CTX}} -n {{.NS}} get svc echo-private-lb \
          -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
        if [ -z "$HOST" ]; then
          echo "ERROR: the echo server has no load balancer hostname — run 'task deploy' first." >&2
          exit 1
        fi
        echo "==> calling $HOST:8080 from a Pod in GKE"
        kubectl --context {{.GCP_CTX}} -n {{.NS}} delete job connectivity-test --ignore-not-found --wait=true
        sed -e "s|__ECHO_HOST__|$HOST|g" deploy/connectivity-test-job.yaml \
          | kubectl --context {{.GCP_CTX}} apply -f -

        # Poll for EITHER outcome rather than `kubectl wait`: a failed connection is a legitimate
        # result, and `--for=condition=complete` would just time out on it, turning "could not reach
        # the other cloud" into "something hung". The failure is the instructive output here.
        OUTCOME=""
        for _ in $(seq 1 60); do
          SUCCEEDED="$(kubectl --context {{.GCP_CTX}} -n {{.NS}} get job connectivity-test -o jsonpath='{.status.succeeded}' 2>/dev/null || true)"
          FAILED="$(kubectl --context {{.GCP_CTX}} -n {{.NS}} get job connectivity-test -o jsonpath='{.status.failed}' 2>/dev/null || true)"
          if [ "$SUCCEEDED" = "1" ]; then OUTCOME=passed; break; fi
          if [ -n "$FAILED" ] && [ "$FAILED" != "0" ]; then OUTCOME=failed; break; fi
          sleep 10
        done

        kubectl --context {{.GCP_CTX}} -n {{.NS}} logs job/connectivity-test || true
        echo ""
        case "$OUTCOME" in
          passed) echo "Connectivity test PASSED." ;;
          failed) echo "Connectivity test FAILED — see the diagnosis above." >&2; exit 1 ;;
          *)      echo "Connectivity test did not finish in time." >&2; exit 1 ;;
        esac

  status:
    desc: 'Show both sides at a glance'
    cmds:
      - echo "=== EKS ==="
      - kubectl --context {{.AWS_CTX}} -n {{.NS}} get pods,svc
      - echo ""
      - echo "=== GKE ==="
      - kubectl --context {{.GCP_CTX}} -n {{.NS}} get pods,jobs

  clean-k8s:
    desc: 'Remove the in-cluster pieces (REQUIRED before `down` — see the note)'
    cmds:
      # Not optional politeness: the internal load balancer is created by Kubernetes, so Terraform does
      # not know it exists. Left behind, its ENIs and security groups keep the VPC alive and
      # `terragrunt destroy` fails partway through with a dependency violation.
      - kubectl --context {{.GCP_CTX}} -n {{.NS}} delete job connectivity-test --ignore-not-found || true
      - kubectl --context {{.GCP_CTX}} delete namespace {{.NS}} --ignore-not-found --wait=false || true
      - kubectl --context {{.AWS_CTX}} delete -f deploy/echo-server.yaml --ignore-not-found || true
      - |
        echo "==> waiting for the AWS load balancer to actually go away"
        for i in $(seq 1 20); do
          REMAINING="$(kubectl --context {{.AWS_CTX}} -n {{.NS}} get svc -o jsonpath='{.items[?(@.spec.type=="LoadBalancer")].metadata.name}' 2>/dev/null || true)"
          [ -z "$REMAINING" ] && { echo "   gone"; break; }
          echo "   still present: $REMAINING ($i/20)"; sleep 15
        done

  down:
    desc: 'Destroy everything (runs clean-k8s first, then all infra on AWS and GCP)'
    cmds:
      - task: clean-k8s
      - task: destroy-infra

  destroy-infra:
    internal: true
    dir: infra
    cmds: [terragrunt run --all destroy --non-interactive]
TASKEOF

# --- 9. README --------------------------------------------------------------------------------------
cat > "$DEST/README.md" <<'READMEEOF'
# aws-gcp/eks-gke-private-vpn

One question, nothing else: **can a Pod in GKE reach a Pod in EKS over private addressing only?**

It stands up an EKS cluster and a GKE Autopilot cluster in separate clouds, joins their VPCs with a
**BGP-routed IPsec VPN** (AWS Site-to-Site VPN ⇄ GCP HA VPN), and proves the path with an echo server
behind an **internal** load balancer. No public listener exists at any point.

The echo server reports **the client address AWS saw**, which is the part worth looking at — see
"What the test actually proves" below.

## Architecture

```
AWS  10.20.0.0/16                              GCP  nodes 10.30.0.0/20, pods 10.31.0.0/16
┌─────────────────────────────┐                ┌────────────────────────────────────────┐
│ EKS  xcvpn-source           │                │ GKE Autopilot  xcvpn-target            │
│                             │                │                                        │
│  echo-server (2 pods)       │◀───────────────│  connectivity-test Job                 │
│  echo-private-lb            │   HA VPN ⇄     │  (a Pod, calling across the VPN)       │
│  INTERNAL load balancer      │  S2S VPN, BGP  │                                        │
│  (no public listener)       │   2 tunnels    │                                        │
└─────────────────────────────┘                └────────────────────────────────────────┘
```

| Unit              | Module                 |
| ----------------- | ---------------------- |
| `aws/network`     | `aws/vpc`              |
| `aws/cluster`     | `aws/eks`              |
| `gcp/network`     | `gcp/vpc`              |
| `gcp/cluster`     | `gcp/gke`              |
| `gcp/vpn-gateway` | `gcp/ha-vpn-gateway`   |
| `aws/vpn`         | `aws/site-to-site-vpn` |
| `gcp/vpn-tunnels` | `gcp/ha-vpn-tunnels`   |

The peering is **three units** because it genuinely cannot be built in one pass: AWS needs the GCP
gateway's interface addresses, and GCP needs the tunnel addresses and pre-shared keys AWS only produces
afterwards. `gcp/vpn-gateway -> aws/vpn -> gcp/vpn-tunnels`.

## Run it

```bash
task init-env      # then edit .env
task init-state

task validate      # cost-free
task build         # cost-free: compile both Go programs
task plan          # cost-free

task up            # both VPCs, both clusters, the three-phase VPN
task vpn-status    # repeat until both tunnels are ESTABLISHED and BGP has learned 10.20.0.0/16
task kubeconfig

task deploy        # echo server on EKS behind an internal load balancer
task test          # a Pod in GKE calls it across the VPN
```

Both programs are Go (`deploy/echo/`, `deploy/probe/`), delivered as ConfigMaps and compiled in-pod by
`go run`. That keeps the lab free of a container registry, which matters more here than usual: a
connectivity lab that needed a working cross-cloud image pull before it could test connectivity would
have the dependency backwards. `go` 1.24+ is needed locally only for `task build`.

**Do not skip `task vpn-status`.** It checks BGP peer state and learned routes, not just tunnel status:
an ASN mismatch leaves tunnels `ESTABLISHED` while nothing routes.

## What the test actually proves

The echo server prints `client_address_as_seen_by_aws`. When a GKE Pod calls it, that is typically a
**GKE Pod address** (`10.31.x.x`), not a node address — because GKE does **not** masquerade Pod traffic
to RFC 1918 destinations.

Pod addresses come from a subnet **secondary** range, which is not a subnet, so a Cloud Router's
`ALL_SUBNETS` advertisement never includes it. So this response only happens because
`gcp/vpn-tunnels` advertises the Pod range explicitly. Remove that advertisement and the request
**hangs** rather than failing — AWS has no route back, and there is nothing to send a rejection with.
That hang is the single most time-consuming failure in this whole setup, which is why the test names it
in its own output.

The test also asserts that the load balancer hostname resolves to a **private** address. An AWS internal
load balancer's hostname is published in **public** DNS but resolves to a private address, so an ordinary
cluster resolver is enough and no private DNS zone is needed.

## Expected non-failures

- The **second tunnel of each AWS VPN connection stays `DOWN`**. An HA VPN interface pairs with one
  connection, so only tunnel 1 of each is used. Two connections exist because each HA VPN interface
  sources traffic from its own address and AWS accepts traffic only from the address its customer
  gateway names — one connection cannot serve both.
- Both Kubernetes **control planes** are public so `kubectl` works from anywhere. Only the control
  planes; the workload path between clusters is private-only.

## Tear down

```bash
task down
```

`down` runs `clean-k8s` first, and that order is **required**: the internal load balancer is created by
Kubernetes, so Terraform does not know it exists. Left behind, its ENIs and security groups keep the VPC
alive and `terragrunt destroy` fails partway through with a dependency violation.

> **Cost.** An EKS control plane, a NAT gateway, 2 small EC2 nodes, a GKE Autopilot cluster, Cloud NAT,
> one internal load balancer, two AWS VPN connections and two Cloud VPN tunnels. VPN connections and
> tunnels bill from creation whether or not traffic flows.

## Learned / decisions

See [`docs/adr/0001-cross-cloud-vpn-topology.md`](docs/adr/0001-cross-cloud-vpn-topology.md).
READMEEOF

# --- 10. ADR ------------------------------------------------------------------------------------------
cat > "$DEST/docs/adr/0001-cross-cloud-vpn-topology.md" <<'ADREOF'
# 0001 — Cross-cloud VPN topology: two connections, three units, and the Pod range

Status: accepted

## Context

Two Kubernetes clusters in two clouds need to talk over private addressing. Both providers document a
BGP-routed IPsec peering: AWS Site-to-Site VPN on one side, Cloud HA VPN on the other.

The configuration looks symmetric, and is not. Three details determine whether it works, and each one
fails in a way that does not point at itself.

## Decision

Peer an AWS Site-to-Site VPN with a GCP HA VPN gateway over BGP. Expose the AWS-side workload on an
**internal** load balancer only. Advertise **both** the GKE node subnet and the GKE Pod secondary range.

## The three details

**One AWS VPN connection per HA VPN interface.** A GCP HA VPN gateway has two interfaces, and each
sources traffic from its own address. AWS accepts traffic on a connection only from the address its
customer gateway names. So a single connection physically cannot serve both interfaces — two are
required. AWS then builds two tunnels per connection, of which this topology uses tunnel 1 of each; **the
other two stay `DOWN` and that is correct.** Expect to second-guess this.

**The peering needs three apply phases.** Each side needs an address the other only produces once it
exists:

```
gcp/ha-vpn-gateway   ->  Google assigns two interface addresses
aws/site-to-site-vpn ->  configured with those; returns tunnel addresses, inside addresses, PSKs
gcp/ha-vpn-tunnels   ->  external gateway + tunnels + BGP, built from those
```

This is why `gcp/ha-vpn-gateway` is a module that creates exactly one resource. Splitting along that
seam lets ordinary `dependency` wiring express the ordering, instead of a targeted apply or a documented
two-pass ritual.

**The GKE Pod range must be advertised explicitly.** Pods draw from a subnet **secondary** range, which
is not a subnet, so `ALL_SUBNETS` never covers it. GKE also does not masquerade Pod traffic to RFC 1918
destinations, so packets reach AWS with a Pod source address AWS has no route back to. The symptom is a
**hang**, not a refusal — the slowest kind to diagnose. Advertising the Pod range alongside the node
subnet makes the path work whether or not Pod traffic is masqueraded. On Autopilot the `ip-masq-agent`
ConfigMap is not editable, so this is the only in-Terraform remedy.

A fourth, adjacent trap: **route propagation on the AWS side is a separate step from the tunnel.** Without
it the tunnels establish, BGP exchanges routes, and traffic still fails — presenting as a one-way network.
The `aws/site-to-site-vpn` module takes `route_table_ids` so this is a named input that can be forgotten
loudly rather than a step buried in a runbook.

## Consequences

- Non-overlapping CIDRs become load-bearing and are documented in `root.hcl`. Overlap makes the two sides
  unroutable in a way no VPN configuration can fix.
- `task up` returning does not mean the VPN is ready. `task vpn-status` checks **BGP peer state and
  learned routes**, because tunnel status alone is not evidence of a working path.
- Tunnels and VPN connections bill hourly from creation, traffic or not.
- Both control planes stay public for operator access; only the workload path is private. The asymmetry
  is deliberate and is the thing worth narrowing first for anything longer-lived.

## Alternatives rejected

- **Public endpoint with an IP allowlist** — simpler and cheaper, and defensible when the exposed thing is
  narrow. Rejected because the private path is this lab's entire subject.
- **Cloud Interconnect / Direct Connect** — the production answer for sustained cross-cloud traffic, but
  needs physical or partner provisioning and cannot be created and destroyed by `task up` / `task down`.
- **WireGuard or Tailscale overlay** — fewer billed resources, but moves the trust boundary into a
  third-party service or a hand-rolled relay, and the thing worth practising is the peering both cloud
  providers document.
- **One connection, both of its tunnels** — halves VPN cost and cannot work: both tunnels terminate on one
  customer gateway, which names a single GCP interface address.
ADREOF

# --- 11. Report -------------------------------------------------------------------------------------
echo ""
echo "==> created $DEST"
find "$DEST" -type f | sed "s|$LABS_ROOT/||" | sort | sed 's/^/    /'
echo ""
echo "Next:"
echo "  cd $DEST"
echo "  terragrunt hcl format"
echo "  task validate          # cost-free; confirms the copied units still resolve"
echo ""
echo "Then review, because this script copied rather than authored the infra units:"
echo "  - every infra/*/terragrunt.hcl source is a pinned ?ref= tag, inherited from the source lab."
echo "    Check the VPN module tags are the ones you want before applying."
echo "  - the CIDR plan in root.hcl is inherited verbatim. If both labs might run at the same time in"
echo "    the same accounts, give this one its own ranges."
