"""Slack event tap — a throwaway debug endpoint.

Stands in for whatever Slack is configured to POST to (e.g. an Amazon Lex channel endpoint) so you
can see exactly what Slack sends. It is invoked through a public Lambda Function URL (payload format
2.0) and does two things:

  1. Logs the full incoming request (method, path, query, headers, raw body) to CloudWatch Logs.
  2. Answers Slack's Events API URL-verification handshake by echoing the `challenge` value; every
     other request just gets a 200 so Slack considers delivery successful.

There is deliberately no Slack request-signature verification here — this is a short-lived debug tap
you spin up, point Slack at, read the logs, and destroy.
"""

import base64
import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _decode_body(event):
    """Return the request body as text, decoding base64 when the Function URL flagged it."""
    body = event.get("body")
    if body is None:
        return ""
    if event.get("isBase64Encoded"):
        try:
            return base64.b64decode(body).decode("utf-8", errors="replace")
        except Exception:  # noqa: BLE001 - debug tool, never fail on a weird body
            return body
    return body


def lambda_handler(event, context):
    http = event.get("requestContext", {}).get("http", {})
    method = http.get("method", "?")
    path = http.get("path", "?")
    raw_body = _decode_body(event)

    # One structured line so it's easy to eyeball / grep in `task slack-debug:logs`.
    logger.info(
        "incoming request %s",
        json.dumps(
            {
                "method": method,
                "path": path,
                "query": event.get("rawQueryString", ""),
                "headers": event.get("headers", {}),
                "body": raw_body,
            },
            default=str,
        ),
    )

    # Slack Events API URL verification: reply with the challenge so Slack marks the URL verified.
    try:
        parsed = json.loads(raw_body) if raw_body else {}
    except json.JSONDecodeError:
        parsed = {}

    if isinstance(parsed, dict) and parsed.get("type") == "url_verification":
        challenge = parsed.get("challenge", "")
        logger.info("url_verification handshake — echoing challenge")
        return {
            "statusCode": 200,
            "headers": {"Content-Type": "application/json"},
            "body": json.dumps({"challenge": challenge}),
        }

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "text/plain"},
        "body": "ok",
    }
