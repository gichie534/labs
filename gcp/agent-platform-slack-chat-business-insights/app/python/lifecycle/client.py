"""Talk to the agent: the deployed engine (traffic split applies), one revision (bypasses it), or in-process.

All three return the same thing — the list of ADK event dicts for one turn — so evals and smoke tests don't care
where the agent runs.
"""

from __future__ import annotations

import os
import uuid
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Target:
    """What to query. ``kind`` is ``local``, ``engine`` or ``revision``."""

    kind: str
    project_id: str
    region: str
    engine_id: str | None = None
    revision_id: str | None = None

    @property
    def engine_name(self) -> str:
        if not self.engine_id:
            raise ValueError("AGENT_ENGINE_ID is required for remote targets")
        return f"projects/{self.project_id}/locations/{self.region}/reasoningEngines/{self.engine_id}"

    @property
    def revision_name(self) -> str:
        if not self.revision_id:
            raise ValueError("a revision ID is required for the revision target")
        rid = self.revision_id.rsplit("/", 1)[-1]
        return f"{self.engine_name}/runtimeRevisions/{rid}"

    def describe(self) -> str:
        if self.kind == "local":
            return "local (in-process ADK runner)"
        if self.kind == "engine":
            return f"engine {self.engine_name} (traffic split applies)"
        return f"revision {self.revision_name}"


def target_from_env(kind: str, revision: str | None = None, env: Mapping[str, str] | None = None) -> Target:
    env = os.environ if env is None else env
    project = env.get("GCP_PROJECT") or env.get("BI_PROJECT_ID")
    if not project:
        raise RuntimeError("Set GCP_PROJECT.")
    return Target(
        kind=kind,
        project_id=project,
        region=env.get("GCP_REGION", "us-central1"),
        engine_id=env.get("AGENT_ENGINE_ID") or None,
        revision_id=revision,
    )


def platform_client(project_id: str, region: str) -> Any:
    """Agent Platform SDK client on v1beta1 (revisions and traffic splitting are v1beta1-only)."""
    import agentplatform

    return agentplatform.Client(project=project_id, location=region, http_options={"api_version": "v1beta1"})


def final_text(events: list[Mapping[str, Any]]) -> str:
    """The agent's answer: text parts of the last model event that has any, ignoring thoughts."""
    for event in reversed(events):
        content = event.get("content") or {}
        if content.get("role") not in (None, "model"):
            continue
        texts = [p["text"] for p in content.get("parts") or [] if p.get("text") and not p.get("thought")]
        if texts:
            return "".join(texts).strip()
    return ""


def turn_error(events: list[Mapping[str, Any]]) -> str:
    """The last error event of the turn, e.g. "MODEL_ARMOR Blocked by Model Armor Floor Setting: ...", or ""."""
    error = ""
    for event in events:
        if event.get("error_code") or event.get("error_message"):
            error = f"{event.get('error_code') or ''} {event.get('error_message') or ''}".strip()
    return error


def tool_calls(events: list[Mapping[str, Any]]) -> list[str]:
    """Names of the tools the agent called, in order."""
    names = []
    for event in events:
        for part in (event.get("content") or {}).get("parts") or []:
            call = part.get("function_call")
            if call and call.get("name"):
                names.append(call["name"])
    return names


async def ask(target: Target, message: str, user_id: str = "eval") -> list[dict[str, Any]]:
    """Send one message in a fresh session and collect the events."""
    if target.kind == "local":
        return await _ask_local(message, user_id)
    client = platform_client(target.project_id, target.region)
    if target.kind == "engine":
        remote = client.runtimes.get(name=target.engine_name)
    elif target.kind == "revision":
        remote = client.runtimes.revisions.get(name=target.revision_name)
    else:
        raise ValueError(f"unknown target kind {target.kind!r}")
    events = []
    async for event in remote.async_stream_query(user_id=user_id, message=message):
        events.append(dict(event))
    return events


async def _ask_local(message: str, user_id: str) -> list[dict[str, Any]]:
    from google.adk.runners import InMemoryRunner
    from google.genai import types

    from business_insights.agent import root_agent

    runner = InMemoryRunner(agent=root_agent, app_name="business_insights")
    session = await runner.session_service.create_session(
        app_name="business_insights", user_id=user_id, session_id=f"local-{uuid.uuid4().hex[:12]}"
    )
    content = types.Content(role="user", parts=[types.Part(text=message)])
    events = []
    async for event in runner.run_async(user_id=user_id, session_id=session.id, new_message=content):
        events.append(event.model_dump(mode="json", exclude_none=True))
    return events
