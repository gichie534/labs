"""Upload microservice — served via a public Lambda Function URL (GET).

Two responsibilities:

  * GET /                       -> serve the upload page (upload.html) and its script (upload.js),
                                   which are packaged in the deployment zip alongside this handler.
  * GET /generate-presigned-url -> mint a short-lived presigned S3 PUT URL so the browser uploads the
                                   image directly to the (private) upload bucket. The bucket stays
                                   private: the presigned URL is the authorization.

The upload page's script posts back to this same Function URL (same origin, relative path), so no
endpoint needs to be injected. Only the "Back to Gallery" link is templated, with the gallery's
public domain from the APP_DOMAIN environment variable.
"""

import json
import os
import secrets
from pathlib import Path

import boto3

s3 = boto3.client("s3")

# Static assets packaged next to this handler in the deployment zip.
ASSETS_DIR = Path(__file__).resolve().parent
DEFAULT_FILE = "upload.html"

CONTENT_TYPES = {
    ".html": "text/html",
    ".js": "application/javascript",
    ".css": "text/css",
}


def lambda_handler(event, context):
    raw_path = event.get("rawPath", "/")
    if raw_path.endswith("/generate-presigned-url"):
        return generate_presigned_url(event)
    return serve_static_file(event)


def generate_presigned_url(event):
    upload_bucket = os.environ["UPLOAD_BUCKET"]

    # Secure random object key under the uploads/ prefix (what the S3 event trigger filters on).
    object_key = f"uploads/{secrets.token_urlsafe(12)}"

    params = event.get("queryStringParameters") or {}
    content_type = params.get("content-type", "binary/octet-stream")

    try:
        url = s3.generate_presigned_url(
            "put_object",
            Params={"Bucket": upload_bucket, "Key": object_key, "ContentType": content_type},
            ExpiresIn=3600,
        )
        return _json(200, {"upload_url": url})
    except Exception as exc:  # pragma: no cover - defensive
        print(f"Error generating pre-signed URL: {exc}")
        return _json(500, {"error": "Error generating pre-signed URL"})


def serve_static_file(event):
    raw_path = event.get("rawPath", "/")
    requested = raw_path.rsplit("/", 1)[-1]
    file_name = requested if ("." in requested) else DEFAULT_FILE

    # Resolve within the assets dir only — reject any path-traversal attempt.
    path = (ASSETS_DIR / file_name).resolve()
    if path.parent != ASSETS_DIR or not path.is_file():
        return _text(404, "Not found")

    content = path.read_text(encoding="utf-8")
    content = _render(content)

    return {
        "statusCode": 200,
        "headers": {"Content-Type": CONTENT_TYPES.get(path.suffix, "text/plain")},
        "body": content,
        "isBase64Encoded": False,
    }


def _render(content):
    """Inject the gallery URL so 'Back to Gallery' returns to the ECS-hosted site."""
    gallery_url = os.environ.get("APP_DOMAIN", "")
    if gallery_url and not gallery_url.startswith("http"):
        gallery_url = f"https://{gallery_url}"
    return content.replace("__GALLERY_URL__", gallery_url)


def _json(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def _text(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "text/plain"},
        "body": body,
    }
