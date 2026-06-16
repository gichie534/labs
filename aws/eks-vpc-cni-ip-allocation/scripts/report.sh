#!/usr/bin/env bash
# ---------------------------------------------------------------------------------------------------------------------
# report.sh — capture one snapshot of the VPC-CNI IP-allocation state for this lab.
#
# The SAME script is called by the Taskfile (tutorial) and the GitHub Actions workflow at each
# phase, so the baseline / scaled / tuned reports are produced by identical logic and are directly
# comparable. It prints a human-readable report to stdout AND writes a machine-readable JSON file
# the Go test consumes to assert the free-IP delta.
#
# Usage:   report.sh <phase-label>
# Example: report.sh phase-1-baseline
#
# Inputs (env):
#   CLUSTER_NAME   EKS cluster name              (default: eks-cni-ip)
#   AWS_REGION     region                        (default: us-east-1)
#   VPC_ID         VPC to scope subnets/ENIs to. If unset, derived from the cluster's VPC.
#   REPORT_DIR     where JSON snapshots are written (default: ./reports)
#   PROBE_CNI      "1" to also exec into an aws-node pod and query the CNI introspection API
#                  (http://localhost:61679/v1/enis). Most fragile bit, off by default.
#
# Requires: aws, kubectl, jq. kubectl must already be pointed at the cluster (the Taskfile runs
# `aws eks update-kubeconfig` first).
# ---------------------------------------------------------------------------------------------------------------------
set -euo pipefail

PHASE="${1:?usage: report.sh <phase-label>}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-cni-ip}"
AWS_REGION="${AWS_REGION:-us-east-1}"
REPORT_DIR="${REPORT_DIR:-./reports}"
PROBE_CNI="${PROBE_CNI:-0}"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

mkdir -p "$REPORT_DIR"
JSON_OUT="$REPORT_DIR/${PHASE}.json"

# Resolve the VPC from the cluster if not provided.
if [[ -z "${VPC_ID:-}" ]]; then
  VPC_ID="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
fi

echo "=============================================================================="
echo "=== VPC CNI IP Report: ${PHASE}   (${TS})"
echo "=== cluster=${CLUSTER_NAME} region=${AWS_REGION} vpc=${VPC_ID}"
echo "=============================================================================="

# ---------------------------------------------------------------------------------------------------------------------
# [1] Private subnet IP availability — the headline metric.
#     EKS tags the lab's private subnets with kubernetes.io/role/internal-elb (set by the vpc module).
# ---------------------------------------------------------------------------------------------------------------------
SUBNETS_JSON="$(aws ec2 describe-subnets --region "$AWS_REGION" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=tag:kubernetes.io/role/internal-elb,Values=1" \
  --query 'Subnets[].{id:SubnetId,cidr:CidrBlock,az:AvailabilityZone,free:AvailableIpAddressCount}' \
  --output json)"

echo
echo "[1] Private subnet IP availability"
echo "$SUBNETS_JSON" | jq -r '.[] | "  \(.id)  \(.cidr)  \(.az)  free=\(.free)"'
TOTAL_FREE="$(echo "$SUBNETS_JSON" | jq '[.[].free] | add // 0')"
echo "  ----------------------------------------------------------------------------"
echo "  TOTAL FREE PRIVATE IPs: ${TOTAL_FREE}"

# ---------------------------------------------------------------------------------------------------------------------
# [2] Node ENIs and secondary IPs. Every ENI attached to a worker instance — the primary ENI AND the
#     CNI's extra ENIs — carries secondary private IPs the VPC CNI has pre-allocated for pods. The
#     true measure of "IPs this node is holding" is the sum of secondary IPs across ALL its ENIs,
#     so we scope by the node instance IDs rather than by ENI description. This is the WHY behind [1].
# ---------------------------------------------------------------------------------------------------------------------
# Instance IDs of the cluster's nodes (providerID looks like aws:///<az>/<instance-id>).
NODE_INSTANCE_IDS="$(kubectl get nodes -o json 2>/dev/null \
  | jq -r '[.items[].spec.providerID | split("/") | last] | join(",")' 2>/dev/null || true)"

if [[ -n "${NODE_INSTANCE_IDS:-}" && "$NODE_INSTANCE_IDS" != "" ]]; then
  ENIS_JSON="$(aws ec2 describe-network-interfaces --region "$AWS_REGION" \
    --filters "Name=attachment.instance-id,Values=${NODE_INSTANCE_IDS}" \
    --query 'NetworkInterfaces[].{eni:NetworkInterfaceId,node:Attachment.InstanceId,desc:Description,secondary:PrivateIpAddresses[?Primary==`false`].PrivateIpAddress}' \
    --output json)"
else
  ENIS_JSON='[]'
fi

echo
echo "[2] Node ENIs and secondary IPs (all ENIs on the worker instances)"
if [[ "$(echo "$ENIS_JSON" | jq 'length')" -eq 0 ]]; then
  echo "  (no node ENIs found yet)"
fi
echo "$ENIS_JSON" | jq -r '.[] | "  \(.node // "?")  \(.eni)  secondary_ips=\(.secondary | length)"'
TOTAL_SECONDARY="$(echo "$ENIS_JSON" | jq '[.[].secondary | length] | add // 0')"
ENI_COUNT="$(echo "$ENIS_JSON" | jq 'length')"
echo "  ----------------------------------------------------------------------------"
echo "  NODE ENIs: ${ENI_COUNT}   TOTAL SECONDARY IPs ALLOCATED TO NODES: ${TOTAL_SECONDARY}"

# ---------------------------------------------------------------------------------------------------------------------
# [3] Kubernetes node capacity — how the ENI math becomes each node's max-pods.
# ---------------------------------------------------------------------------------------------------------------------
echo
echo "[3] Kubernetes node capacity (allocatable pods vs running)"
NODES_JSON='[]'
if kubectl get nodes >/dev/null 2>&1; then
  NODES_JSON="$(kubectl get nodes -o json | jq -c '
    [.items[] | {
      name: .metadata.name,
      allocatable_pods: (.status.allocatable.pods | tonumber)
    }]')"
  # Running (non-terminated) pods per node.
  PODS_BY_NODE="$(kubectl get pods -A --field-selector=status.phase=Running -o json \
    | jq -c '[.items[].spec.nodeName] | group_by(.) | map({key: .[0], value: length}) | from_entries')"
  NODES_JSON="$(jq -cn --argjson nodes "$NODES_JSON" --argjson running "$PODS_BY_NODE" '
    [$nodes[] | . + {running_pods: ($running[.name] // 0)}]')"
  echo "$NODES_JSON" | jq -r '.[] | "  \(.name)  allocatable_pods=\(.allocatable_pods)  running=\(.running_pods)"'
else
  echo "  (kubectl not configured for this cluster — skipping)"
fi
NODE_COUNT="$(echo "$NODES_JSON" | jq 'length')"

# ---------------------------------------------------------------------------------------------------------------------
# [4] Live aws-node (VPC CNI) configuration — see the IP-target env vars change between phases.
# ---------------------------------------------------------------------------------------------------------------------
echo
echo "[4] Live aws-node CNI configuration"
WARM_IP="unset"; MIN_IP="unset"; WARM_ENI="unset"
if kubectl -n kube-system get daemonset aws-node >/dev/null 2>&1; then
  CNI_ENV="$(kubectl -n kube-system get daemonset aws-node -o json \
    | jq -c '[.spec.template.spec.containers[] | select(.name=="aws-node") | .env[]?] | map({(.name): .value}) | add // {}')"
  WARM_IP="$(echo "$CNI_ENV" | jq -r '.WARM_IP_TARGET // "unset"')"
  MIN_IP="$(echo "$CNI_ENV" | jq -r '.MINIMUM_IP_TARGET // "unset"')"
  WARM_ENI="$(echo "$CNI_ENV" | jq -r '.WARM_ENI_TARGET // "unset(default 1)"')"
  echo "  WARM_IP_TARGET     = ${WARM_IP}"
  echo "  MINIMUM_IP_TARGET  = ${MIN_IP}"
  echo "  WARM_ENI_TARGET    = ${WARM_ENI}"

  if [[ "$PROBE_CNI" == "1" ]]; then
    echo
    echo "  CNI introspection (/v1/enis) from one aws-node pod:"
    POD="$(kubectl -n kube-system get pods -l k8s-app=aws-node -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
    if [[ -n "$POD" ]]; then
      kubectl -n kube-system exec "$POD" -c aws-node -- \
        curl -s http://localhost:61679/v1/enis 2>/dev/null \
        | jq -r '"    total_ips=\(.TotalIPs)  assigned=\(.AssignedIPs)"' 2>/dev/null \
        || echo "    (introspection unavailable)"
    fi
  fi
else
  echo "  (aws-node daemonset not found — skipping)"
fi

# ---------------------------------------------------------------------------------------------------------------------
# JSON snapshot for the Go test.
# ---------------------------------------------------------------------------------------------------------------------
jq -n \
  --arg phase "$PHASE" \
  --arg ts "$TS" \
  --arg cluster "$CLUSTER_NAME" \
  --arg vpc "$VPC_ID" \
  --arg warm_ip "$WARM_IP" \
  --arg min_ip "$MIN_IP" \
  --argjson total_free "$TOTAL_FREE" \
  --argjson total_secondary "$TOTAL_SECONDARY" \
  --argjson eni_count "$ENI_COUNT" \
  --argjson node_count "$NODE_COUNT" \
  --argjson subnets "$SUBNETS_JSON" \
  --argjson nodes "$NODES_JSON" \
  '{
     phase: $phase, timestamp: $ts, cluster: $cluster, vpc: $vpc,
     total_free_private_ips: $total_free,
     total_secondary_ips: $total_secondary,
     cni_eni_count: $eni_count,
     node_count: $node_count,
     warm_ip_target: $warm_ip,
     minimum_ip_target: $min_ip,
     subnets: $subnets,
     nodes: $nodes
   }' > "$JSON_OUT"

echo
echo "Wrote JSON snapshot: ${JSON_OUT}"
