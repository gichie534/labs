# The debug tap itself: a single Python Lambda fronted by a public Lambda Function URL (no API
# Gateway, no VPC). Slack POSTs here; the handler logs the full request to CloudWatch and echoes the
# Events API url_verification challenge. See app/python/handler.py.
#
# The deployment zip is built by `task slack-debug:build` (zips app/python/handler.py to
# build/function.zip). Run build before plan/up; the module hashes the zip so rebuilds redeploy.
#
# Sourced from the modules repo by pinned tag.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/lambda?ref=aws-lambda-v0.3.0"
}

inputs = {
  name = "slack-event-debug"

  # Built by `task slack-debug:build` into the lab-root build/ dir.
  filename = "${get_terragrunt_dir()}/../../build/function.zip"
  handler  = "handler.lambda_handler"
  runtime  = "python3.12"

  # Public HTTPS endpoint that invokes the function directly — this is the URL you paste into Slack.
  # NONE = unauthenticated, which Slack's webhook requires (it can't sign SigV4).
  create_function_url             = true
  function_url_authorization_type = "NONE"

  # Debug logs; short retention so a forgotten tap doesn't accumulate.
  log_retention_in_days = 1

  tags = {
    Environment = "lab"
  }
}
