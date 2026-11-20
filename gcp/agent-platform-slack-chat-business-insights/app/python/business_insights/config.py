"""Runtime settings for the business-insights agent.

Everything comes from environment variables. The deploy pipeline (``deploy/release.py``) sets them on every
revision, so each revision carries its own configuration; locally ``task dev`` exports them from the lab's
``.env``. Defaults follow the lab's naming convention (``root.hcl``), so normally only the project is needed.
"""

from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass
from functools import lru_cache


@dataclass(frozen=True)
class Settings:
    """Where the agent's data lives and which model it uses."""

    project_id: str
    region: str
    model: str
    model_location: str
    analytics_dataset: str
    crm_instance: str
    crm_database: str
    crm_reader_service_account: str
    docs_bucket: str
    timezone: str
    release: str

    @property
    def analytics_dataset_ref(self) -> str:
        """Fully qualified BigQuery dataset, e.g. ``my-project.bi_analytics``."""
        return f"{self.project_id}.{self.analytics_dataset}"


def from_env(env: Mapping[str, str] | None = None) -> Settings:
    """Build settings from ``env`` (default: ``os.environ``).

    Raises:
        RuntimeError: if no project is configured.
    """
    env = os.environ if env is None else env
    # BI_PROJECT_ID is set explicitly at deploy time. GOOGLE_CLOUD_PROJECT is the local fallback.
    project = env.get("BI_PROJECT_ID") or env.get("GOOGLE_CLOUD_PROJECT")
    if not project:
        raise RuntimeError("Set BI_PROJECT_ID (or GOOGLE_CLOUD_PROJECT) to the lab's project ID.")
    region = env.get("BI_REGION", "us-central1")
    return Settings(
        project_id=project,
        region=region,
        model=env.get("BI_MODEL", "gemini-3.8-flash"),
        # Gemini 3.8 Flash is served from the global endpoint, not from the agent's region.
        model_location=env.get("BI_MODEL_LOCATION", "global"),
        analytics_dataset=env.get("BI_ANALYTICS_DATASET", "bi_analytics"),
        crm_instance=env.get("BI_CRM_INSTANCE", "bi-crm"),
        crm_database=env.get("BI_CRM_DATABASE", "crm"),
        # The service account the agent borrows for Cloud SQL IAM database authentication.
        crm_reader_service_account=env.get("BI_CRM_READER_SA", f"bi-crm-reader@{project}.iam.gserviceaccount.com"),
        docs_bucket=env.get("BI_DOCS_BUCKET", f"{project}-bi-docs"),
        timezone=env.get("BI_TIMEZONE", "UTC"),
        release=env.get("BI_RELEASE", "local"),
    )


@lru_cache(maxsize=1)
def settings() -> Settings:
    """Process-wide settings, read once."""
    return from_env()
