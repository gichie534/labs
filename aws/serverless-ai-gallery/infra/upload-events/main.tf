# Lab-local glue — NOT reusable infra: connect the upload bucket's ObjectCreated events to the push
# Lambda, and grant S3 permission to invoke it.

variable "upload_bucket_id" {
  description = "ID (name) of the upload bucket whose events trigger the push Lambda."
  type        = string
}

variable "upload_bucket_arn" {
  description = "ARN of the upload bucket (source ARN for the invoke permission)."
  type        = string
}

variable "push_function_name" {
  description = "Name of the push Lambda to invoke on upload."
  type        = string
}

variable "push_function_arn" {
  description = "ARN of the push Lambda (notification target)."
  type        = string
}

# S3 may invoke the push function for events from this bucket.
resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = var.push_function_name
  principal     = "s3.amazonaws.com"
  source_arn    = var.upload_bucket_arn
}

# Fire the push function on new objects under uploads/.
resource "aws_s3_bucket_notification" "uploads" {
  bucket = var.upload_bucket_id

  lambda_function {
    lambda_function_arn = var.push_function_arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = "uploads/"
  }

  depends_on = [aws_lambda_permission.allow_s3]
}
