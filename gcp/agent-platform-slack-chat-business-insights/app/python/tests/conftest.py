"""Test environment: a fake project, no credentials needed for unit tests."""

from __future__ import annotations

import os

import pytest

os.environ.setdefault("BI_PROJECT_ID", "test-project")
os.environ.setdefault("BI_REGION", "us-central1")
os.environ.setdefault("BI_RELEASE", "test")
# Keep google-auth from probing for a client certificate on the developer's machine.
os.environ.setdefault("GOOGLE_API_USE_CLIENT_CERTIFICATE", "false")


@pytest.fixture(autouse=True)
def _fresh_settings():
    from business_insights import config

    config.settings.cache_clear()
    yield
    config.settings.cache_clear()
