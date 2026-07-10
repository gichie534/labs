# Upload microservice Lambda — serves the upload page (packaged upload.html/upload.js) and mints
# presigned S3 PUT URLs, exposed via a public Function URL. The page's script calls the presigned-URL
# endpoint same-origin, so no CORS is needed on the URL.
#
# ignore_code_changes = true: Terraform creates the function from the initial build, then CI owns code
# rollouts (`aws lambda update-function-code`). Build the zip first (`task package`, wired as a dep of
# validate/plan/up). filename must be ABSOLUTE (Terraform hashes it from the terragrunt cache dir).
#
# Sourced from the modules repo by pinned tag (lambda v0.3.0 adds Function URLs + layers).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/lambda?ref=aws-lambda-v0.3.0"
}

dependency "uploads" {
  config_path = "../../s3-buckets/uploads"

  mock_outputs = {
    bucket = "mock-uploads-bucket"
    arn    = "arn:aws:s3:::mock-uploads-bucket"
  }
}

inputs = {
  name     = "ai-gallery-upload"
  filename = "${get_terragrunt_dir()}/../../../app/lambdas/upload/build/upload.zip"

  handler      = "upload.lambda_handler"
  runtime      = "python3.12"
  architecture = "x86_64"
  memory_size  = 256
  timeout      = 15

  environment_variables = {
    UPLOAD_BUCKET = dependency.uploads.outputs.bucket
    APP_DOMAIN    = get_env("APP_DOMAIN", "REPLACE_WITH_APP_DOMAIN")
  }

  # Public HTTPS endpoint that mints presigned URLs. CORS allows the gallery page (a different origin)
  # to call /generate-presigned-url from the browser now that upload is a modal on the gallery.
  create_function_url = true
  function_url_cors = {
    allow_methods = ["GET"]
    allow_origins = ["*"]
  }

  # Least privilege: the function only mints presigned PUT URLs, which requires PutObject on the
  # upload bucket (the presigned URL inherits the function's permission).
  inline_policies = {
    upload = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "PutUploads"
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = "${dependency.uploads.outputs.arn}/uploads/*"
        },
      ]
    })
  }

  ignore_code_changes = true

  tags = {
    Environment = "lab"
  }
}
