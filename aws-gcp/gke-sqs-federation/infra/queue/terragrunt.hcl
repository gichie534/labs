# The AWS SQS queue the workloads exchange messages through. Standard queue with long polling so the
# reader's ReceiveMessage waits for work instead of busy-spinning. Sourced from the modules repo by
# pinned tag.
#
# This unit owns ONLY the queue. The send/receive permissions are attached to the two IAM roles in
# the federation unit, which consumes this unit's `arn` output. Keeping the queue and the IAM split
# in separate units mirrors the module boundary (the sqs module is intentionally IAM-free).
#
# TODO(release): the aws/sqs module must be tagged in the catalog as `aws-sqs-v0.1.0` before this lab
# is "done". Until then this ref will not resolve; switch to a local path while iterating if needed:
#   source = "../../../../infrastructure-catalog/modules/aws/sqs"

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/sqs?ref=aws-sqs-v0.1.0"
}

inputs = {
  name = "gke-sqs-federation"

  # Long polling — the reader blocks up to 20s for a message rather than returning empty immediately.
  receive_wait_time_seconds = 20

  # Above the reader's per-message processing time so an in-flight message isn't redelivered.
  visibility_timeout_seconds = 30

  tags = {
    Lab       = "gke-sqs-federation"
    ManagedBy = "terragrunt"
  }
}
