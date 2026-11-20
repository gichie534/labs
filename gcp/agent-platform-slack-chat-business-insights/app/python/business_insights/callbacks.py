"""Agent callbacks: deterministic guardrails around the model.

``pin_tool_arguments`` runs before every tool call and overwrites the arguments that decide WHERE a query runs
and WHO it runs as. The model only chooses the SQL. A prompt-injected "query instance prod-db as postgres" can't
redirect a call: the instance, database and billing project are set here, in code, from the revision's
configuration, and the Cloud SQL login fields (``user``, ``passwordSecretVersion``) are removed, so the Data API
always logs in with IAM database authentication as the caller — the borrowed bi-crm-reader service account.

``remember_conversation`` runs after each agent turn and hands the session to Memory Bank, which extracts the
long-term memories configured on the Agent Runtime instance (reporting preferences, focus areas).
"""

from __future__ import annotations

import logging
from typing import Any

from business_insights.config import Settings, settings
from business_insights.tools.google_mcp import BIGQUERY_PREFIX, CLOUDSQL_PREFIX

logger = logging.getLogger(__name__)

# BigQuery job timeout. Keeps a runaway query from running for minutes.
BIGQUERY_JOB_TIMEOUT_MS = "60000"


# Arguments removed from a call before it runs. With `user` + `passwordSecretVersion` the Cloud SQL Data API would
# switch to a built-in database login; without them it uses IAM database authentication as the caller.
REMOVED_ARGUMENTS = {
    f"{CLOUDSQL_PREFIX}_execute_sql_readonly": ("user", "passwordSecretVersion"),
}


def pinned_arguments(tool_name: str, s: Settings) -> dict[str, Any]:
    """Arguments forced onto a tool call, by tool name. Empty for tools that need none."""
    if tool_name == f"{CLOUDSQL_PREFIX}_execute_sql_readonly":
        return {
            "project": s.project_id,
            "instance": s.crm_instance,
            "database": s.crm_database,
            # Tags each statement with the MCP tool and caller identity (visible in Cloud SQL query insights).
            "sqlCommenterEnabled": True,
        }
    if tool_name == f"{BIGQUERY_PREFIX}_execute_sql_readonly":
        return {
            "projectId": s.project_id,
            "jobTimeoutMs": BIGQUERY_JOB_TIMEOUT_MS,
            # Job labels make the agent's BigQuery spend attributable (INFORMATION_SCHEMA.JOBS, billing export).
            "labels": {"agent": "business-insights", "release": _label_value(s.release)},
        }
    if tool_name.startswith(f"{BIGQUERY_PREFIX}_"):
        return {"projectId": s.project_id}
    return {}


def _label_value(value: str) -> str:
    """Coerce to a valid BigQuery label value (lowercase, digits, - and _, max 63)."""
    cleaned = "".join(c if c.isalnum() or c in "-_" else "-" for c in value.lower())
    return cleaned[:63] or "unknown"


def pin_tool_arguments(tool: Any, args: dict[str, Any], tool_context: Any) -> dict[str, Any] | None:
    """before_tool_callback: overwrite routing/identity arguments in place, then let the call proceed."""
    name = getattr(tool, "name", "")
    removed = sorted(k for k in REMOVED_ARGUMENTS.get(name, ()) if k in args)
    for key in removed:
        args.pop(key)
    pins = pinned_arguments(name, settings())
    overridden = sorted(k for k, v in pins.items() if k in args and args[k] != v)
    if removed or overridden:
        logger.warning("Tool %s: removed model-chosen %s, overrode %s", name, removed, overridden)
    args.update(pins)
    return None


async def remember_conversation(callback_context: Any) -> None:
    """after_agent_callback: send the session to Memory Bank. Never fails the turn."""
    try:
        await callback_context.add_session_to_memory()
    except Exception as exc:  # noqa: BLE001 - memory is best-effort
        logger.warning("Memory generation skipped: %s", exc)
    return None
