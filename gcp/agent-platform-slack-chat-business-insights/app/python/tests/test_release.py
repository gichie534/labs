from lifecycle import release
from lifecycle.client import Target, final_text, target_from_env, tool_calls

TARGET = Target(kind="engine", project_id="acme", region="us-central1", engine_id="123")


def test_update_config_ships_source_as_a_revision():
    cfg = release.update_config(TARGET, {"RELEASE": "abc123"})
    assert cfg["source_packages"] == ["business_insights"]
    assert (cfg["entrypoint_module"], cfg["entrypoint_object"]) == ("business_insights.runtime_app", "app")
    assert cfg["requirements_file"] == "business_insights/requirements.txt"
    assert {m["name"] for m in cfg["class_methods"]} >= {"async_stream_query", "async_create_session"}
    # Scaling is versioned with the code (the API refuses a deployment_spec on a code-less engine).
    assert (cfg["min_instances"], cfg["max_instances"]) == (0, 3)
    assert cfg["resource_limits"] == {"cpu": "2", "memory": "4Gi"}
    # Identity and labels belong to Terraform; the gateway binding is its own step. A release touches neither.
    assert not {"identity_type", "labels", "agent_gateway_config"} & cfg.keys()


def test_scaling_overrides():
    cfg = release.update_config(TARGET, {"AGENT_MAX_INSTANCES": "10", "AGENT_CPU": "4", "AGENT_MEMORY": "8Gi"})
    assert cfg["max_instances"] == 10
    assert cfg["resource_limits"] == {"cpu": "4", "memory": "8Gi"}


def test_gateway_config_accepts_short_and_full_names():
    full = "projects/acme/locations/us-central1/agentGateways/bi-agents-egress"
    assert release.gateway_config("acme", "us-central1", "bi-agents-egress") == {
        "agent_to_anywhere_config": {"agent_gateway": full}
    }
    assert release.gateway_config("acme", "us-central1", full)["agent_to_anywhere_config"]["agent_gateway"] == full


def test_revision_env_is_self_describing():
    env = release.agent_env(TARGET, {"RELEASE": "abc123", "CAPTURE_MESSAGE_CONTENT": "false"})
    assert env["BI_PROJECT_ID"] == "acme"
    assert env["BI_RELEASE"] == "abc123"
    assert env["GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY"] == "true"
    assert env["OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT"] == "false"
    # Reserved by Agent Runtime.
    assert not {
        k
        for k in env
        if k.startswith("GOOGLE_CLOUD_AGENT_ENGINE_") and k != "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY"
    }
    assert "GOOGLE_CLOUD_PROJECT" not in env and "GOOGLE_CLOUD_LOCATION" not in env


def test_targets():
    t = target_from_env("revision", "999", {"GCP_PROJECT": "acme", "AGENT_ENGINE_ID": "123"})
    assert t.revision_name == "projects/acme/locations/us-central1/reasoningEngines/123/runtimeRevisions/999"
    assert release._resolve(t.engine_name, f"{t.engine_name}/runtimeRevisions/999") == t.revision_name


def test_final_text_and_tools():
    events = [
        {"content": {"role": "model", "parts": [{"function_call": {"name": "cloudsql_execute_sql_readonly"}}]}},
        {"content": {"role": "user", "parts": [{"function_response": {"name": "cloudsql_execute_sql_readonly"}}]}},
        {"content": {"role": "model", "parts": [{"text": "hmm", "thought": True}, {"text": "42 customers."}]}},
    ]
    assert final_text(events) == "42 customers."
    assert tool_calls(events) == ["cloudsql_execute_sql_readonly"]
