# Push microservice Lambda — triggered by an S3 ObjectCreated event on the upload bucket (wired in
# the upload-events unit). It resizes large images, copies them into the website-assets bucket under
# images/, and writes a metadata row to DynamoDB. Pillow is provided by a layer, not the zip.
#
# No Function URL: this one is event-driven, invoked by S3.
#
# Sourced from the modules repo by pinned tag (lambda v0.3.0 adds layers).

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

dependency "assets" {
  config_path = "../../s3-buckets/assets"

  mock_outputs = {
    bucket = "mock-assets-bucket"
    arn    = "arn:aws:s3:::mock-assets-bucket"
  }
}

dependency "table" {
  config_path = "../../dynamodb"

  mock_outputs = {
    name = "mock-table"
    arn  = "arn:aws:dynamodb:us-east-1:000000000000:table/mock-table"
  }
}

inputs = {
  name     = "ai-gallery-push"
  filename = "${get_terragrunt_dir()}/../../../app/lambdas/push/build/push.zip"

  handler      = "push.lambda_handler"
  runtime      = "python3.12"
  architecture = "x86_64"
  memory_size  = 2048
  timeout      = 60

  # Pillow (PIL) for image processing, provided by a public Klayers layer.
  layers = [get_env("PILLOW_LAYER_ARN", "arn:aws:lambda:us-east-1:770693421928:layer:Klayers-p312-Pillow:11")]

  environment_variables = {
    UPLOAD_BUCKET         = dependency.uploads.outputs.bucket
    WEBSITE_ASSETS_BUCKET = dependency.assets.outputs.bucket
    DYNAMODB_TABLE        = dependency.table.outputs.name
  }

  inline_policies = {
    push = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ReadUploads"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = "${dependency.uploads.outputs.arn}/uploads/*"
        },
        {
          Sid      = "WriteAssets"
          Effect   = "Allow"
          Action   = ["s3:PutObject"]
          Resource = "${dependency.assets.outputs.arn}/images/*"
        },
        {
          Sid      = "WriteMetadata"
          Effect   = "Allow"
          Action   = ["dynamodb:PutItem", "dynamodb:UpdateItem"]
          Resource = dependency.table.outputs.arn
        },
      ]
    })
  }

  ignore_code_changes = true

  tags = {
    Environment = "lab"
  }
}
