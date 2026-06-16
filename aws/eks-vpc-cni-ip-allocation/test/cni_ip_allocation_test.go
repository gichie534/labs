// Package test holds the assertive red/green check for the VPC-CNI IP-allocation lab.
//
// The lab's thesis is: tuning the VPC CNI with WARM_IP_TARGET / MINIMUM_IP_TARGET makes nodes hold
// FEWER idle ("warm") secondary IPs, which RETURNS free IPs to the subnet. This test proves that.
//
// It works off the JSON snapshots that scripts/report.sh writes at each phase (the single source
// of truth shared with the tutorial and CI), so the assertion matches exactly what a human reads.
//
// Two layers:
//   - TestTunedReportFreesIPs (always): compares the phase-2 (scaled, untuned) and phase-3 (tuned)
//     JSON snapshots and asserts the subnet free-IP count went UP and secondary IPs went DOWN.
//   - TestLiveSubnetsMatchReport (RUN_LIVE=1): cross-checks the recorded numbers against a live
//     AWS EC2 DescribeSubnets call, so the snapshots can't silently go stale.
//
// Run after the phases have produced reports/:
//
//	go test ./...                       # snapshot delta assertions (offline, free)
//	RUN_LIVE=1 AWS_REGION=us-east-1 \
//	  VPC_ID=vpc-... go test ./...       # also hit live AWS to validate the snapshot
package test

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"

	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/ec2"
	"github.com/stretchr/testify/require"
)

// report mirrors the JSON written by scripts/report.sh.
type report struct {
	Phase             string   `json:"phase"`
	Cluster           string   `json:"cluster"`
	VPC               string   `json:"vpc"`
	TotalFreeIPs      int      `json:"total_free_private_ips"`
	TotalSecondaryIPs int      `json:"total_secondary_ips"`
	CNIENICount       int      `json:"cni_eni_count"`
	NodeCount         int      `json:"node_count"`
	WarmIPTarget      string   `json:"warm_ip_target"`
	MinimumIPTarget   string   `json:"minimum_ip_target"`
	Subnets           []subnet `json:"subnets"`
}

type subnet struct {
	ID   string `json:"id"`
	CIDR string `json:"cidr"`
	AZ   string `json:"az"`
	Free int    `json:"free"`
}

func reportsDir() string {
	if d := os.Getenv("REPORT_DIR"); d != "" {
		return d
	}
	return filepath.Join("..", "reports")
}

func loadReport(t *testing.T, phase string) report {
	t.Helper()
	path := filepath.Join(reportsDir(), phase+".json")
	data, err := os.ReadFile(path)
	require.NoErrorf(t, err, "missing snapshot %s — run the phase that produces it first (task ...:report-*)", path)
	var r report
	require.NoError(t, json.Unmarshal(data, &r), "snapshot %s is not valid JSON", path)
	return r
}

// TestTunedReportFreesIPs is the core red/green assertion: after tuning the CNI, the same cluster
// holds fewer secondary IPs and the subnets regain free addresses.
func TestTunedReportFreesIPs(t *testing.T) {
	scaled := loadReport(t, "phase-2-scaled")
	tuned := loadReport(t, "phase-3-tuned")

	// Sanity: the tuned snapshot must actually have the CNI knobs set, the scaled one must not.
	require.Equal(t, "unset", scaled.WarmIPTarget, "phase-2 should be the UNTUNED baseline (WARM_IP_TARGET unset)")
	require.NotEqual(t, "unset", tuned.WarmIPTarget, "phase-3 should have WARM_IP_TARGET set")

	// Compare like-for-like: node count shouldn't change between scaled and tuned phases.
	require.Equal(t, scaled.NodeCount, tuned.NodeCount,
		"node count must match between phases to isolate the CNI effect (scaled=%d tuned=%d)",
		scaled.NodeCount, tuned.NodeCount)

	t.Logf("secondary IPs: scaled=%d -> tuned=%d", scaled.TotalSecondaryIPs, tuned.TotalSecondaryIPs)
	t.Logf("free subnet IPs: scaled=%d -> tuned=%d", scaled.TotalFreeIPs, tuned.TotalFreeIPs)

	require.Less(t, tuned.TotalSecondaryIPs, scaled.TotalSecondaryIPs,
		"tuning WARM_IP_TARGET/MINIMUM_IP_TARGET should reduce idle secondary IPs held by nodes")
	require.Greater(t, tuned.TotalFreeIPs, scaled.TotalFreeIPs,
		"reclaimed secondary IPs should return free addresses to the private subnets")
}

// TestLiveSubnetsMatchReport guards against stale snapshots by re-reading the live subnet free-IP
// counts from AWS and comparing them to the most recent (tuned) report. Opt-in via RUN_LIVE=1.
func TestLiveSubnetsMatchReport(t *testing.T) {
	if os.Getenv("RUN_LIVE") != "1" {
		t.Skip("set RUN_LIVE=1 (and AWS creds) to cross-check snapshots against live AWS")
	}
	tuned := loadReport(t, "phase-3-tuned")

	ctx := context.Background()
	cfg, err := config.LoadDefaultConfig(ctx)
	require.NoError(t, err)
	client := ec2.NewFromConfig(cfg)

	for _, s := range tuned.Subnets {
		out, err := client.DescribeSubnets(ctx, &ec2.DescribeSubnetsInput{
			SubnetIds: []string{s.ID},
		})
		require.NoError(t, err)
		require.Len(t, out.Subnets, 1, "subnet %s not found live", s.ID)

		live := awsInt(out.Subnets[0].AvailableIpAddressCount)
		// Allow drift of a few IPs (pods churn between snapshot and test); the point is the snapshot
		// isn't wildly out of date.
		require.InDeltaf(t, s.Free, live, 5,
			"subnet %s recorded free=%d but live free=%d", s.ID, s.Free, live)
	}
}

func awsInt(p *int32) int {
	if p == nil {
		return 0
	}
	return int(*p)
}
