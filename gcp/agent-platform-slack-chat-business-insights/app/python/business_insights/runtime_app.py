"""Agent Runtime entrypoint (``entrypoint_module=business_insights.runtime_app``, ``entrypoint_object=app``).

On Agent Runtime, AdkApp wires the agent to the platform's managed services: Agent Platform Sessions (the Slack
thread maps to a session), Memory Bank (long-term memories per user) and Cloud Trace telemetry.
"""

from agentplatform.frameworks import AdkApp

from business_insights.agent import root_agent

app = AdkApp(agent=root_agent, app_name="business_insights")
