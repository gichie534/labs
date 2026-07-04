# Lab-local seed unit (local path). Uploads the jpg/pdf assets and the generated index.html. Depends
# on all three bucket units so the buckets exist first. `get_terragrunt_dir()` resolves the assets
# dir relative to this unit, so the path works regardless of where `terragrunt` is invoked from.

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "."
}

dependency "site" {
  config_path = "../bucket-site"
  mock_outputs = {
    bucket = "mock-site-bucket"
  }
}

dependency "jpg" {
  config_path = "../bucket-jpg"
  mock_outputs = {
    bucket = "mock-jpg-bucket"
  }
}

dependency "pdf" {
  config_path = "../bucket-pdf"
  mock_outputs = {
    bucket = "mock-pdf-bucket"
  }
}

inputs = {
  site_bucket = dependency.site.outputs.bucket
  jpg_bucket  = dependency.jpg.outputs.bucket
  pdf_bucket  = dependency.pdf.outputs.bucket
  assets_dir  = "${get_terragrunt_dir()}/../../app/assets"
}
