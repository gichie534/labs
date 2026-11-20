import pytest

from business_insights.config import from_env


def test_defaults_follow_the_lab_naming_convention():
    s = from_env({"BI_PROJECT_ID": "acme-lab", "BI_REGION": "europe-west1"})
    assert s.analytics_dataset_ref == "acme-lab.bi_analytics"
    assert s.crm_instance == "bi-crm"
    assert s.docs_bucket == "acme-lab-bi-docs"
    # Cloud SQL is reached as this borrowed service account (IAM database authentication, no password).
    assert s.crm_reader_service_account == "bi-crm-reader@acme-lab.iam.gserviceaccount.com"
    assert (s.model, s.model_location) == ("gemini-3.8-flash", "global")


def test_falls_back_to_google_cloud_project():
    assert from_env({"GOOGLE_CLOUD_PROJECT": "p-1"}).project_id == "p-1"


def test_requires_a_project():
    with pytest.raises(RuntimeError):
        from_env({})
