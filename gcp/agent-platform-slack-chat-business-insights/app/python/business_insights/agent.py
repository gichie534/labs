"""The business-insights agent (ADK).

``root_agent`` is what ``adk web`` / ``adk run`` load locally. ``runtime_app.app`` wraps it for Agent Runtime.
"""

from __future__ import annotations

from google.adk.agents import Agent
from google.adk.models import Gemini
from google.adk.tools.preload_memory_tool import PreloadMemoryTool

from business_insights.callbacks import pin_tool_arguments, remember_conversation
from business_insights.config import settings
from business_insights.instructions import instruction_provider
from business_insights.tools.glossary import read_business_glossary
from business_insights.tools.google_mcp import bigquery_toolset, cloudsql_toolset

_s = settings()

root_agent = Agent(
    name="business_insights",
    description="Answers business questions about TheLook customers, orders, revenue and web activity.",
    # The model is called through Agent Platform ("enterprise") as the agent identity, from the global
    # endpoint. Model Armor screens every one of these calls (floor setting, infra/model-armor/floor-setting).
    model=Gemini(
        model=_s.model,
        client_kwargs={"enterprise": True, "project": _s.project_id, "location": _s.model_location},
    ),
    instruction=instruction_provider,
    tools=[
        read_business_glossary,
        # Called as the borrowed bi-crm-reader service account (Cloud SQL IAM database authentication).
        cloudsql_toolset(_s.project_id, _s.crm_reader_service_account),
        bigquery_toolset(_s.project_id),
        # Loads this user's long-term memories (Memory Bank) into the turn.
        PreloadMemoryTool(),
    ],
    before_tool_callback=pin_tool_arguments,
    after_agent_callback=remember_conversation,
)
