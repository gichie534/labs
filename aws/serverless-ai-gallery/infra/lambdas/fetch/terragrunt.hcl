# Fetch microservice Lambda — lists processed images, hands out presigned GET URLs, and joins in the
# DynamoDB descriptions. Exposed via a public Function URL (GET) with CORS so the gallery page (served
# from a different origin, the app domain) can call it from the browser.
#
# Sourced from the modules repo by pinned tag (lambda v0.3.0 adds Function URLs).

include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "git::https://github.com/gichie534/infrastructure-catalog.git//modules/aws/lambda?ref=aws-lambda-v0.3.0"
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
  name     = "ai-gallery-fetch"
  filename = "${get_terragrunt_dir()}/../../../app/lambdas/fetch/build/fetch.zip"

  handler      = "fetch.lambda_handler"
  runtime      = "python3.12"
  architecture = "x86_64"
  memory_size  = 256
  timeout      = 30

  environment_variables = {
    WEBSITE_ASSETS_BUCKET = dependency.assets.outputs.bucket
    DYNAMODB_TABLE        = dependency.table.outputs.name
  }

  create_function_url = true
  function_url_cors = {
    allow_methods = ["GET"]
    allow_origins = ["*"]
  }

  inline_policies = {
    fetch = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ListAndReadAssets"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:ListBucket"]
          Resource = [dependency.assets.outputs.arn, "${dependency.assets.outputs.arn}/images/uploads*"]
        },
        {
          Sid      = "ReadMetadata"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:Query"]
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
