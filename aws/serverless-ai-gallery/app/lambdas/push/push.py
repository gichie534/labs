"""Push microservice — triggered by an S3 ObjectCreated event on the upload bucket (uploads/ prefix).

For each uploaded object it: downloads the image, resizes it if it is large, copies it into the
website-assets bucket under images/<key>, and writes a metadata row to DynamoDB (keyed by the
original upload key) with a placeholder description the AI microservice later fills in.

Pillow (PIL) is provided by a Lambda layer, not bundled in the deployment zip.
"""

import io
import os
from datetime import datetime, timezone

import boto3
from PIL import Image

s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")

MAX_BYTES = 4.5 * 1024 * 1024  # resize anything larger than ~4.5 MB


def lambda_handler(event, context):
    upload_bucket = os.environ["UPLOAD_BUCKET"]
    assets_bucket = os.environ["WEBSITE_ASSETS_BUCKET"]
    table_name = os.environ["DYNAMODB_TABLE"]
    table = dynamodb.Table(table_name)

    for record in event["Records"]:
        source_key = record["s3"]["object"]["key"]
        source_bucket = record["s3"]["bucket"]["name"]

        if source_bucket != upload_bucket:
            print(f"Event from unexpected bucket {source_bucket}, expected {upload_bucket}; skipping.")
            continue

        image_obj = s3_client.get_object(Bucket=source_bucket, Key=source_key)
        image = Image.open(image_obj["Body"])
        image_format = image.format or "JPEG"

        if image_obj["ContentLength"] > MAX_BYTES:
            print(f"Resizing {source_key} (exceeds size limit).")
            image = resize_image(image)

        buffer = io.BytesIO()
        image.save(buffer, format=image_format)

        destination_key = f"images/{source_key}"
        s3_client.put_object(
            Bucket=assets_bucket,
            Key=destination_key,
            Body=buffer.getvalue(),
            ContentType=f"image/{image_format.lower()}",
        )
        print(f"Copied image to {assets_bucket}/{destination_key}")

        table.put_item(
            Item={
                "ImageKey": source_key,
                "AI_Description": "AI description not yet generated",
                "UploadTime": datetime.now(timezone.utc).isoformat(),
            }
        )
        print(f"DynamoDB row written for {source_key}")

    return {"statusCode": 200, "body": "Function executed successfully"}


def resize_image(image, base_width=1024):
    """Resize to base_width, preserving aspect ratio."""
    w_percent = base_width / float(image.size[0])
    h_size = int(float(image.size[1]) * w_percent)
    return image.resize((base_width, h_size), Image.Resampling.LANCZOS)
