# The heart of the lab: keyless GKE -> AWS authentication via OIDC web identity federation.
#
# The GKE cluster is itself an OIDC identity provider. We register its issuer URL as an AWS IAM OIDC
# provider, then create TWO IAM roles whose trust policies are scoped (by the token `sub` claim) to
# exactly one Kubernetes service account each:
#
#   - writer role  <- trusts subject system:serviceaccount:sqsdemo:writer ; may only sqs:SendMessage
#   - reader role  <- trusts subject system:serviceaccount:sqsdemo:reader ; may only Receive/Delete/GetAttrs
#
# A pod mounts a projected SA token (audience sts.amazonaws.com); the AWS SDK calls
# AssumeRoleWithWebIdentity with the role ARN + token; STS validates the token against this provider
# and the role's trust policy, then returns short-lived credentials. No static AWS keys anywhere.
#
# This reuses the IdP-neutral aws/oidc-federation module (the same one used for GitHub->AWS CI),
# pointing provider_url at the GKE issuer instead of GitHub's.

include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

locals {
  k8s_namespace = include.root.locals.k8s_namespace
  writer_ksa    = include.root.locals.writer_ksa
  reader_ksa    = include.root.locals.reader_ksa
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/oidc-federation?ref=aws-oidc-federation-v0.1.0"
}

# The cluster IS the OIDC provider. Its cluster_id is projects/<project-id>/locations/<region>/clusters/<name>;
# the GKE issuer URL (the token's `iss` claim) is that path under https://container.googleapis.com/v1/.
# AWS matches the provider URL against `iss` exactly, so we build it from a real value in state.
dependency "cluster" {
  config_path = "../cluster"

  mock_outputs = {
    cluster_id = "projects/mock/locations/mock/clusters/mock"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

# The queue the roles are scoped to. Its arn feeds both inline policies.
dependency "queue" {
  config_path = "../queue"

  mock_outputs = {
    arn = "arn:aws:sqs:us-east-1:000000000000:mock-queue"
  }
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
}

inputs = {
  name_prefix = "gke-sqs-federation-"

  # The GKE cluster's OIDC issuer. AWS fetches its public JWKS over the internet to verify tokens.
  provider_url   = "https://container.googleapis.com/v1/${dependency.cluster.outputs.cluster_id}"
  client_id_list = ["sts.amazonaws.com"]

  roles = {
    # Writer: trusted only for the writer KSA; may only send messages.
    writer = {
      subjects = ["system:serviceaccount:${local.k8s_namespace}:${local.writer_ksa}"]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "AllowSend"
            Effect   = "Allow"
            Action   = ["sqs:SendMessage"]
            Resource = dependency.queue.outputs.arn
          },
        ]
      })
    }

    # Reader: trusted only for the reader KSA; may only receive/delete and read attributes.
    reader = {
      subjects = ["system:serviceaccount:${local.k8s_namespace}:${local.reader_ksa}"]
      inline_policy = jsonencode({
        Version = "2012-10-17"
        Statement = [
          {
            Sid      = "AllowReceive"
            Effect   = "Allow"
            Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
            Resource = dependency.queue.outputs.arn
          },
        ]
      })
    }
  }

  tags = {
    Lab       = "gke-sqs-federation"
    ManagedBy = "terragrunt"
  }
}
