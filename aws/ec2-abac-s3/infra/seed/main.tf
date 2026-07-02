# Lab-local seed — NOT reusable infra, just the test fixture the demonstration reads: a single
# object (probe.txt) in the demo bucket. It lives in its own tiny unit so it can be created AFTER the
# bucket exists but BEFORE the instances boot (their boot-time probe reads this object). Creating an
# object isn't the S3 module's job, and this is lab-specific glue, so it's a local unit.

variable "bucket" {
  description = "Name of the demo bucket to seed the probe object into."
  type        = string
  nullable    = false
}

resource "aws_s3_object" "probe" {
  bucket       = var.bucket
  key          = "probe.txt"
  content      = "abac-lab: if you can read this, the principal tag project=abac-lab satisfied the bucket policy.\n"
  content_type = "text/plain"
}

output "key" {
  description = "Key of the seeded probe object."
  value       = aws_s3_object.probe.key
}
