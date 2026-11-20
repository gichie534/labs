import asyncio
from types import SimpleNamespace

from business_insights import callbacks
from business_insights.config import from_env


def tool(name):
    return SimpleNamespace(name=name)


def test_cloudsql_routing_is_pinned_and_login_fields_removed():
    args = {
        "sqlStatement": "SELECT count(*) FROM users",
        # What a prompt-injected model might try:
        "instance": "prod-db",
        "user": "postgres",
        "passwordSecretVersion": "projects/x/locations/us-central1/secrets/stolen/versions/1",
        "project": "someone-elses-project",
    }
    assert callbacks.pin_tool_arguments(tool("cloudsql_execute_sql_readonly"), args, None) is None
    # No user/password: the Data API logs in with IAM database authentication as the caller (bi-crm-reader).
    assert args == {
        "sqlStatement": "SELECT count(*) FROM users",
        "project": "test-project",
        "instance": "bi-crm",
        "database": "crm",
        "sqlCommenterEnabled": True,
    }


def test_bigquery_billing_project_timeout_and_labels_are_pinned():
    args = {"query": "SELECT 1", "projectId": "other"}
    callbacks.pin_tool_arguments(tool("bigquery_execute_sql_readonly"), args, None)
    assert args["projectId"] == "test-project"
    assert args["jobTimeoutMs"] == "60000"
    assert args["labels"] == {"agent": "business-insights", "release": "test"}
    assert args["query"] == "SELECT 1"


def test_other_bigquery_tools_get_the_project_and_function_tools_nothing():
    args = {"datasetId": "bi_analytics"}
    callbacks.pin_tool_arguments(tool("bigquery_list_table_ids"), args, None)
    assert args == {"datasetId": "bi_analytics", "projectId": "test-project"}
    args = {}
    callbacks.pin_tool_arguments(tool("read_business_glossary"), args, None)
    assert args == {}


def test_release_label_is_sanitized():
    s = from_env({"BI_PROJECT_ID": "p", "BI_RELEASE": "ABC123-Dirty/x"})
    assert callbacks.pinned_arguments("bigquery_execute_sql_readonly", s)["labels"]["release"] == "abc123-dirty-x"


def test_memory_failures_never_fail_the_turn():
    class Ctx:
        async def add_session_to_memory(self):
            raise ValueError("memory service is not available")

    assert asyncio.run(callbacks.remember_conversation(Ctx())) is None
