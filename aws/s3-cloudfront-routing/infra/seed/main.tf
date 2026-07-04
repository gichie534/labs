# Lab-local seed — NOT reusable infra. It populates the three buckets with content and generates the
# static site's index.html so the whole thing is browsable end to end:
#   - every file in app/assets/jpg  -> the jpg bucket (served via CloudFront at /<filename>)
#   - every file in app/assets/pdf  -> the pdf bucket (served via CloudFront at /<filename>)
#   - a generated index.html        -> the site bucket, linking to each uploaded file by /<filename>
#
# Because CloudFront routes *.jpg and *.pdf to the other buckets, a relative link like "/photo.jpg"
# from the site resolves to the jpg bucket automatically — the links match the path routing by design.
# This is lab-specific glue, so it's a local unit, ordered after the buckets exist.

variable "site_bucket" {
  description = "Name of the static-website bucket to upload the generated index.html into."
  type        = string
  nullable    = false
}

variable "jpg_bucket" {
  description = "Name of the bucket that receives the .jpg assets."
  type        = string
  nullable    = false
}

variable "pdf_bucket" {
  description = "Name of the bucket that receives the .pdf assets."
  type        = string
  nullable    = false
}

variable "assets_dir" {
  description = "Absolute path to the lab's app/assets directory (contains jpg/ and pdf/ subdirs)."
  type        = string
  nullable    = false
}

locals {
  jpg_files = fileset("${var.assets_dir}/jpg", "*.jpg")
  pdf_files = fileset("${var.assets_dir}/pdf", "*.pdf")

  # Links point at /<filename>; CloudFront's *.jpg / *.pdf behaviors route them to the right bucket.
  jpg_links = [for f in local.jpg_files : "    <li><a href=\"/${f}\">${f}</a></li>"]
  pdf_links = [for f in local.pdf_files : "    <li><a href=\"/${f}\">${f}</a></li>"]

  index_html = <<-HTML
    <!DOCTYPE html>
    <html lang="en">
    <head><meta charset="utf-8"><title>s3-cloudfront-routing</title></head>
    <body>
      <h1>s3-cloudfront-routing</h1>
      <p>This page is served from the <strong>site</strong> bucket. The links below are served from
      separate <strong>jpg</strong> and <strong>pdf</strong> buckets — CloudFront routes them by path.</p>
      <h2>Images (.jpg)</h2>
      <ul>
    ${join("\n", local.jpg_links)}
      </ul>
      <h2>Documents (.pdf)</h2>
      <ul>
    ${join("\n", local.pdf_links)}
      </ul>
    </body>
    </html>
  HTML
}

resource "aws_s3_object" "jpg" {
  for_each = local.jpg_files

  bucket       = var.jpg_bucket
  key          = each.value
  source       = "${var.assets_dir}/jpg/${each.value}"
  etag         = filemd5("${var.assets_dir}/jpg/${each.value}")
  content_type = "image/jpeg"
}

resource "aws_s3_object" "pdf" {
  for_each = local.pdf_files

  bucket       = var.pdf_bucket
  key          = each.value
  source       = "${var.assets_dir}/pdf/${each.value}"
  etag         = filemd5("${var.assets_dir}/pdf/${each.value}")
  content_type = "application/pdf"
}

resource "aws_s3_object" "index" {
  bucket       = var.site_bucket
  key          = "index.html"
  content      = local.index_html
  content_type = "text/html"
}

output "index_key" {
  description = "Key of the generated site index."
  value       = aws_s3_object.index.key
}

output "jpg_keys" {
  description = "Keys uploaded to the jpg bucket."
  value       = [for o in aws_s3_object.jpg : o.key]
}

output "pdf_keys" {
  description = "Keys uploaded to the pdf bucket."
  value       = [for o in aws_s3_object.pdf : o.key]
}
