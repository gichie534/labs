"""The agent builds without credentials or network, and is wired the way the lab expects."""

from google.adk.tools.preload_memory_tool import PreloadMemoryTool

from business_insights.callbacks import pin_tool_arguments, remember_conversation


def test_root_agent_wiring():
    from business_insights.agent import root_agent

    assert root_agent.name == "business_insights"
    assert root_agent.model.model == "gemini-3.8-flash"
    prefixes = {getattr(t, "tool_name_prefix", None) for t in root_agent.tools}
    assert {"bigquery", "cloudsql"} <= prefixes
    assert any(isinstance(t, PreloadMemoryTool) for t in root_agent.tools)
    assert root_agent.before_tool_callback is pin_tool_arguments
    assert root_agent.after_agent_callback is remember_conversation


def test_runtime_entrypoint_is_an_adk_app():
    from agentplatform.frameworks import AdkApp

    from business_insights.runtime_app import app

    assert isinstance(app, AdkApp)
