# ---------------------------------------------------------------------------------------------------------------------
# ROOT CONFIGURATION (v3 - directory-as-hierarchy, lean)
#
# The directory tree under hierarchy/ mirrors the GCP org hierarchy. Every node is a `terragrunt.hcl` that
# includes one of the templates in _envcommon/:
#   - root-folder.hcl : a folder directly under the organization (parent is a static org string)
#   - folder.hcl      : a folder nested under another folder (parent resolved from the directory above)
#   - project.hcl     : a project (parent folder resolved from the directory above)
#
# Org-wide settings live here. There is no separate org.hcl and no org passthrough unit.
# ---------------------------------------------------------------------------------------------------------------------

locals {
  org_id          = "567753225689"
  billing_account = "019E4C-949B0A-B4C549"
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<-EOF
    provider "google" {}
  EOF
}

remote_state {
  backend = "gcs"
  config = {
    bucket   = "richardbatyrov-test-org-bucket"
    prefix   = "${path_relative_to_include()}/terraform.tfstate"
    project  = "infra-bootstrap-498907"
    location = "europe-north1"
  }
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
}
