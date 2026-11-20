"""The business glossary: metric definitions and reporting rules, read from the docs bucket.

A plain function tool (not MCP) using the Cloud Storage client library. Like the MCP tools it runs as the agent
identity, which has objectViewer on the docs bucket and nothing else in Cloud Storage.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any

from google.cloud import storage

from business_insights.config import settings

DOCS_PREFIX = "docs/"
_CACHE_SECONDS = 300.0
_MAX_DOC_BYTES = 64 * 1024

_cache: dict[str, Any] = {"at": 0.0, "docs": None}


def _load(bucket: str, client_factory: Callable[[], Any]) -> list[dict[str, str]]:
    client = client_factory()
    docs = []
    for blob in client.list_blobs(bucket, prefix=DOCS_PREFIX):
        if not blob.name.endswith(".md"):
            continue
        content = blob.download_as_bytes()[:_MAX_DOC_BYTES].decode("utf-8", errors="replace")
        docs.append({"name": blob.name.removeprefix(DOCS_PREFIX), "content": content})
    return sorted(docs, key=lambda d: d["name"])


def load_documents(
    bucket: str | None = None,
    client_factory: Callable[[], Any] | None = None,
    now: Callable[[], float] = time.monotonic,
) -> list[dict[str, str]]:
    """All glossary documents, cached for a few minutes per process."""
    if _cache["docs"] is not None and now() - _cache["at"] < _CACHE_SECONDS:
        return _cache["docs"]
    s = settings()
    docs = _load(
        bucket or s.docs_bucket,
        client_factory or (lambda: storage.Client(project=s.project_id)),
    )
    _cache.update(at=now(), docs=docs)
    return docs


def read_business_glossary() -> dict[str, Any]:
    """Return TheLook's official metric definitions, reporting periods and data-source map.

    Call this once per conversation before computing any metric (revenue, orders, active customers,
    conversion, return rate) or interpreting a period ("last month", "trend", "this month vs last month"),
    and follow the definitions exactly.

    Returns:
        A dict with a ``documents`` list; each document has a ``name`` and its Markdown ``content``.
    """
    try:
        return {"status": "ok", "documents": load_documents()}
    except Exception as exc:  # noqa: BLE001 - surface the failure to the model instead of crashing the turn
        return {"status": "error", "error": f"Could not read the glossary: {exc}"}
