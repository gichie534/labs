# AI microservice Lambda — fetches an image, sends it to Amazon Bedrock (Claude Haiku via a
# cross-region inference profile) for a description, and stores that on the image's DynamoDB row.
# Exposed via a public Function URL (POST) with CORS so the gallery page can call it from the browser.
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
  name     = "ai-gallery-ai"
  filename = "${get_terragrunt_dir()}/../../../app/lambdas/ai/build/ai.zip"

  handler      = "ai.lambda_handler"
  runtime      = "python3.12"
  architecture = "x86_64"
  memory_size  = 512
  timeout      = 300

  environment_variables = {
    WEBSITE_ASSETS_BUCKET = dependency.assets.outputs.bucket
    DYNAMODB_TABLE        = dependency.table.outputs.name
    BEDROCK_MODEL_ID      = get_env("BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0")
  }

  create_function_url = true
  function_url_cors = {
    allow_methods = ["POST"]
    allow_origins = ["*"]
    allow_headers = ["content-type"]
  }

  inline_policies = {
    ai = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Sid      = "ReadAssets"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = "${dependency.assets.outputs.arn}/images/*"
        },
        {
          Sid      = "WriteMetadata"
          Effect   = "Allow"
          Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
          Resource = dependency.table.outputs.arn
        },
        {
          Sid    = "InvokeBedrock"
          Effect = "Allow"
          Action = ["bedrock:InvokeModel"]
          # Inference profiles route across regions; "*" covers the profile ARN and the underlying
          # foundation-model ARNs in each destination region. Scope this down in production.
          Resource = "*"
        },
      ]
    })
  }

  ignore_code_changes = true

  tags = {
    Environment = "lab"
  }
}
