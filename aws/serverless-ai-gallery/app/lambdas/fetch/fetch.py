"""Fetch microservice — served via a public Lambda Function URL (GET).

Lists the processed images in the website-assets bucket (images/uploads prefix), generates a
short-lived presigned GET URL for each (the bucket is private), looks up the matching AI description
in DynamoDB, and returns a JSON array of { url, description } for the gallery to render.
"""

import json
import logging
import os
from decimal import Decimal

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3_client = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")


class DecimalEncoder(json.JSONEncoder):
    def default(self, obj):
        if isinstance(obj, Decimal):
            return float(obj)
        return super().default(obj)


def lambda_handler(event, context):
    assets_bucket = os.environ["WEBSITE_ASSETS_BUCKET"]
    table = dynamodb.Table(os.environ["DYNAMODB_TABLE"])

    images_data = []
    try:
        objects = s3_client.list_objects_v2(Bucket=assets_bucket, Prefix="images/uploads")

        for obj in objects.get("Contents", []):
            image_key = obj["Key"]  # e.g. images/uploads/<id>

            presigned_url = s3_client.generate_presigned_url(
                "get_object",
                Params={"Bucket": assets_bucket, "Key": image_key},
                ExpiresIn=3600,
            )

            # The DynamoDB row is keyed by the original upload key: uploads/<id>.
            dynamodb_key = "uploads/" + image_key.split("/")[-1]
            response = table.get_item(Key={"ImageKey": dynamodb_key})

            ai_description = "No description available"
            if "Item" in response:
                ai_description = response["Item"].get("AI_Description", ai_description)

            images_data.append({"url": presigned_url, "description": ai_description})
    except Exception as exc:
        logger.error("An error occurred: %s", str(exc))
        raise

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(images_data, cls=DecimalEncoder),
    }
