"""AI microservice — served via a public Lambda Function URL (POST).

Given { "imageId": "<id>" }, it fetches the processed image from the website-assets bucket, sends it
to Amazon Bedrock (Claude Haiku via a cross-region inference profile) to generate a description, and
stores that description back on the image's DynamoDB row.

The model is set via BEDROCK_MODEL_ID and defaults to the Claude Haiku 4.5 US cross-region inference
profile. Newer Claude models on Bedrock must be invoked through an inference profile (the bare
foundation-model id is not enabled for on-demand invocation), which is why the default carries the
`us.` prefix.
"""

import base64
import json
import os

import boto3

DYNAMODB_TABLE = os.environ["DYNAMODB_TABLE"]
IMAGE_BUCKET = os.environ["WEBSITE_ASSETS_BUCKET"]
MODEL_ID = os.environ.get("BEDROCK_MODEL_ID", "us.anthropic.claude-haiku-4-5-20251001-v1:0")

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")
bedrock_runtime = boto3.client("bedrock-runtime")

PROMPT = (
    "Analyze the image provided and generate a concise, engaging description suitable for a general "
    "audience. Start with an overview of the scene, followed by specific details about the main "
    "subjects and notable background elements. Focus on the emotions displayed, any apparent "
    "activities, and significant objects. Use descriptive but straightforward language. Avoid "
    "technical terms and ensure the text is ready for display on a webpage."
)


def lambda_handler(event, context):
    body = json.loads(event.get("body", "{}") or "{}")
    image_id_raw = body.get("imageId", "")

    # The gallery derives the id from a presigned URL, so strip any query string.
    image_id = image_id_raw.split("?")[0]
    if not image_id:
        return _json(400, {"error": "imageId is required"})

    print(f"Generating description for image id: {image_id}")

    image_bytes = get_image(IMAGE_BUCKET, f"images/uploads/{image_id}")
    description = generate_summary(image_bytes)
    store_in_dynamodb(image_id, description)

    return _json(200, {"imageId": image_id, "description": description})


def get_image(bucket, key):
    return s3.get_object(Bucket=bucket, Key=key)["Body"].read()


def generate_summary(image_bytes):
    media_type = _sniff_media_type(image_bytes)
    image_base64 = base64.b64encode(image_bytes).decode()

    response = bedrock_runtime.invoke_model(
        modelId=MODEL_ID,
        contentType="application/json",
        accept="application/json",
        body=json.dumps(
            {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 1000,
                "system": PROMPT,
                "messages": [
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "image",
                                "source": {
                                    "type": "base64",
                                    "media_type": media_type,
                                    "data": image_base64,
                                },
                            },
                            {"type": "text", "text": "Describe this image."},
                        ],
                    }
                ],
            }
        ),
    )

    result = json.loads(response["body"].read().decode())
    # Messages API: text lives in content[0].text.
    parts = result.get("content", [])
    if parts and isinstance(parts, list):
        return parts[0].get("text", "").strip()
    return "No description generated."


def store_in_dynamodb(image_id, description):
    table = dynamodb.Table(DYNAMODB_TABLE)
    dynamodb_key = f"uploads/{image_id}"
    table.put_item(Item={"ImageKey": dynamodb_key, "AI_Description": description})
    print(f"Stored description for {dynamodb_key}")


def _sniff_media_type(data):
    if data[:3] == b"\xff\xd8\xff":
        return "image/jpeg"
    if data[:8] == b"\x89PNG\r\n\x1a\n":
        return "image/png"
    if data[:6] in (b"GIF87a", b"GIF89a"):
        return "image/gif"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return "image/jpeg"


def _json(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }
