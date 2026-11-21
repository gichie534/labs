"""Ship the agent as Agent Runtime revisions and move traffic between them.

    python -m lifecycle.release release            # new revision at 0% (first release: 100%)
    python -m lifecycle.release status             # revisions and the current split
    python -m lifecycle.release canary  --revision R --percent 10
    python -m lifecycle.release promote --revision R
    python -m lifecycle.release rollback
    python -m lifecycle.release latest             # "always latest" (needed before an Agent Gateway binding change)
    python -m lifecycle.release gateway --egress G # bind the agent's egress to Agent Gateway G (preview)
    python -m lifecycle.release smoke   --revision R

The engine itself (identity, Memory Bank, invokers) is created by Terraform (infra/agent-runtime/business-insights).
This script owns everything that changes with a release — source, entrypoint, class methods, env and scaling —
and updating those *versioned fields* makes the platform create an immutable revision of the same engine. Same
engine ID, same Agent Identity, same IAM grants. (The API refuses a deployment_spec on an engine with no code, so
scaling can't be set by Terraform anyway.)

Environment: GCP_PROJECT, GCP_REGION, AGENT_ENGINE_ID; optional RELEASE (default: git SHA), BI_MODEL,
BI_MODEL_LOCATION, BI_TIMEZONE, CAPTURE_MESSAGE_CONTENT (default true), AGENT_MIN_INSTANCES (0),
AGENT_MAX_INSTANCES (3), AGENT_CPU (2), AGENT_MEMORY (4Gi), AGENT_CONCURRENCY (5).
"""

from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import os
import subprocess
import sys
from collections.abc import Mapping
from pathlib import Path
from typing import Any

from lifecycle import traffic
from lifecycle.client import Target, ask, final_text, platform_client, target_from_env, tool_calls

APP_DIR = Path(__file__).resolve().parents[1]

# AdkApp's operations, as Agent Runtime must expose them. Deploying from source requires listing them explicitly.
CLASS_METHODS: list[dict[str, Any]] = [
    {"name": "get_session", "api_mode": ""},
    {"name": "list_sessions", "api_mode": ""},
    {"name": "create_session", "api_mode": ""},
    {"name": "delete_session", "api_mode": ""},
    {"name": "async_get_session", "api_mode": "async"},
    {"name": "async_list_sessions", "api_mode": "async"},
    {"name": "async_create_session", "api_mode": "async"},
    {"name": "async_delete_session", "api_mode": "async"},
    {"name": "async_add_session_to_memory", "api_mode": "async"},
    {"name": "async_search_memory", "api_mode": "async"},
    {"name": "stream_query", "api_mode": "stream"},
    {"name": "async_stream_query", "api_mode": "async_stream"},
    {"name": "streaming_agent_run_with_events", "api_mode": "async_stream"},
]

SMOKE_QUESTION = "In one sentence: how many orders were placed yesterday?"


def release_id(env: Mapping[str, str]) -> str:
    """RELEASE, else the short git SHA, else a UTC timestamp."""
    if env.get("RELEASE"):
        return env["RELEASE"]
    try:
        sha = subprocess.run(
            ["git", "rev-parse", "--short=12", "HEAD"], capture_output=True, text=True, check=True, cwd=APP_DIR
        ).stdout.strip()
        dirty = subprocess.run(["git", "status", "--porcelain", "."], capture_output=True, text=True, cwd=APP_DIR)
        return f"{sha}-dirty" if dirty.stdout.strip() else sha
    except (OSError, subprocess.CalledProcessError):
        return dt.datetime.now(dt.UTC).strftime("%Y%m%d%H%M%S")


def agent_env(target: Target, env: Mapping[str, str]) -> dict[str, str]:
    """Environment of the new revision. Versioned: every revision keeps the env it was released with."""
    return {
        "BI_PROJECT_ID": target.project_id,
        "BI_REGION": target.region,
        "BI_MODEL": env.get("BI_MODEL", "gemini-3.5-flash"),
        "BI_MODEL_LOCATION": env.get("BI_MODEL_LOCATION", "global"),
        "BI_TIMEZONE": env.get("BI_TIMEZONE", "UTC"),
        "BI_RELEASE": release_id(env),
        # Agent Runtime telemetry: OpenTelemetry traces and logs for every model and tool call.
        "GOOGLE_CLOUD_AGENT_ENGINE_ENABLE_TELEMETRY": "true",
        # Prompts and responses in trace spans. Great for learning and debugging; it also stores customer data
        # in Cloud Trace. Set CAPTURE_MESSAGE_CONTENT=false for anything real.
        "OTEL_INSTRUMENTATION_GENAI_CAPTURE_MESSAGE_CONTENT": env.get("CAPTURE_MESSAGE_CONTENT", "true"),
    }


def scaling(env: Mapping[str, str]) -> dict[str, Any]:
    """Runtime resources of the new revision. Versioned like the code: a rollback restores the old sizing too."""
    return {
        # Scale to zero between questions; a couple of instances are plenty for a Slack channel.
        "min_instances": int(env.get("AGENT_MIN_INSTANCES", "0")),
        "max_instances": int(env.get("AGENT_MAX_INSTANCES", "3")),
        "resource_limits": {"cpu": env.get("AGENT_CPU", "2"), "memory": env.get("AGENT_MEMORY", "4Gi")},
        # Google recommends 2 * cpu + 1.
        "container_concurrency": int(env.get("AGENT_CONCURRENCY", "5")),
    }


def update_config(target: Target, env: Mapping[str, str]) -> dict[str, Any]:
    """The runtimes.update config that creates a revision from local source."""
    return {
        "source_packages": ["business_insights"],
        "entrypoint_module": "business_insights.runtime_app",
        "entrypoint_object": "app",
        "requirements_file": "business_insights/requirements.txt",
        "class_methods": CLASS_METHODS,
        "agent_framework": "google-adk",
        "env_vars": agent_env(target, env),
        **scaling(env),
    }


def gateway_config(project_id: str, region: str, egress_gateway: str) -> dict[str, Any]:
    """agent_gateway_config binding the agent's outbound traffic to an Agent-to-Anywhere gateway."""
    name = egress_gateway
    if "/" not in name:
        name = f"projects/{project_id}/locations/{region}/agentGateways/{egress_gateway}"
    return {"agent_to_anywhere_config": {"agent_gateway": name}}


# --- API helpers -----------------------------------------------------------------------------------------------


# The API names a revision by project ID in revisions.list but by project NUMBER in the traffic config, so every
# name read from the API is rewritten to `<engine>/runtimeRevisions/<id>`, with the engine name as configured.
def _revisions(client: Any, engine: str) -> list[traffic.Revision]:
    out = []
    for rev in client.runtimes.revisions.list(name=engine):
        res = rev.api_resource
        state = getattr(res.state, "value", None) or str(res.state or "")
        created = res.create_time or dt.datetime.min.replace(tzinfo=dt.UTC)
        out.append(traffic.Revision(name=_resolve(engine, res.name), state=state, create_time=created))
    return out


def _manual_targets(client: Any, engine: str) -> dict[str, int] | None:
    res = client.runtimes.get(name=engine).api_resource
    tc = res.traffic_config
    if tc is None or tc.traffic_split_manual is None:
        return None
    targets: dict[str, int] = {}
    for t in tc.traffic_split_manual.targets or []:
        name = _resolve(engine, t.runtime_revision_name)
        targets[name] = targets.get(name, 0) + int(t.percent or 0)
    return targets


def _apply_split(client: Any, engine: str, split: Mapping[str, int]) -> None:
    from agentplatform import types

    split = traffic.validate(split)
    config = types.ReasoningEngineTrafficConfig(
        traffic_split_manual=types.ReasoningEngineTrafficConfigTrafficSplitManual(
            targets=[
                types.ReasoningEngineTrafficConfigTrafficSplitManualTarget(runtime_revision_name=n, percent=p)
                for n, p in sorted(split.items())
            ]
        )
    )
    client.runtimes.update(name=engine, config={"traffic_config": config})


def _apply_always_latest(client: Any, engine: str) -> None:
    from agentplatform import types

    config = types.ReasoningEngineTrafficConfig(
        traffic_split_always_latest=types.ReasoningEngineTrafficConfigTrafficSplitAlwaysLatest()
    )
    client.runtimes.update(name=engine, config={"traffic_config": config})


def _resolve(engine: str, revision: str) -> str:
    rid = revision.rsplit("/", 1)[-1]
    return f"{engine}/runtimeRevisions/{rid}"


def _print_split(split: Mapping[str, int], revisions: list[traffic.Revision]) -> None:
    print(f"{'REVISION':<24} {'STATE':<10} {'CREATED (UTC)':<20} TRAFFIC")
    for r in sorted(revisions, key=lambda r: r.create_time, reverse=True):
        created = r.create_time.astimezone(dt.UTC).strftime("%Y-%m-%d %H:%M:%S")
        print(f"{r.short_id:<24} {r.state:<10} {created:<20} {split.get(r.name, 0)}%")


def _github_output(**values: str) -> None:
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            for k, v in values.items():
                fh.write(f"{k}={v}\n")


# --- Commands --------------------------------------------------------------------------------------------------


def cmd_release(target: Target, client: Any, env: Mapping[str, str]) -> str:
    engine = target.engine_name
    before = _revisions(client, engine)
    split = traffic.current_split(_manual_targets(client, engine), before)

    if split:
        # Freeze the current traffic BEFORE updating, so the new revision starts at 0% instead of taking 100%
        # under "always latest".
        _apply_split(client, engine, split)
        print(f"Pinned current traffic: {split}")

    config = update_config(target, env)
    print(f"Creating a revision of {engine} (release {config['env_vars']['BI_RELEASE']}) ...")
    os.chdir(APP_DIR)  # source_packages are resolved relative to the working directory
    client.runtimes.update(name=engine, config=config)

    after = _revisions(client, engine)
    new = traffic.newest(after, exclude=[r.name for r in before])
    if new is None:
        raise SystemExit("The update completed but no new revision appeared; see the engine's logs.")

    if not split:
        _apply_split(client, engine, traffic.pin(new.name))
        print(f"First release: {new.short_id} takes 100% of traffic.")
    else:
        print(f"New revision {new.short_id} is ACTIVE at 0%. Evaluate it, then canary/promote it.")
    _github_output(revision=new.short_id)
    return new.short_id


def cmd_gateway(target: Target, client: Any, egress_gateway: str) -> None:
    """Bind the agent's egress to an Agent Gateway. Archives every existing revision (platform behaviour)."""
    engine = target.engine_name
    # Binding changes are only accepted while traffic is "always latest".
    _apply_always_latest(client, engine)
    config = gateway_config(target.project_id, target.region, egress_gateway)
    print(f"Binding {engine} egress to {config['agent_to_anywhere_config']['agent_gateway']} ...")
    client.runtimes.update(name=engine, config={"agent_gateway_config": config})
    print("Bound. Existing revisions are archived; the next release creates a fresh one.")


def cmd_status(target: Target, client: Any) -> None:
    engine = target.engine_name
    revisions = _revisions(client, engine)
    manual = _manual_targets(client, engine)
    split = traffic.current_split(manual, revisions)
    print(f"Engine {engine}  mode={'manual' if manual else 'always-latest'}")
    _print_split(split, revisions)


def cmd_set(target: Target, client: Any, action: str, revision: str | None, percent: int) -> None:
    engine = target.engine_name
    revisions = _revisions(client, engine)
    split = traffic.current_split(_manual_targets(client, engine), revisions)
    known = {r.name for r in traffic.active(revisions)}
    if revision:
        revision = _resolve(engine, revision)
        if revision not in known:
            raise SystemExit(f"{revision} is not an active revision of {engine}")
    if action == "canary":
        new_split = traffic.canary(split, revision, percent)
    elif action == "promote":
        new_split = traffic.pin(revision)
    else:
        new_split = traffic.rollback(split, revisions)
    print(f"{action}: {split} -> {new_split}")
    _apply_split(client, engine, new_split)
    _print_split(new_split, revisions)


async def cmd_smoke(target: Target) -> None:
    events = await ask(target, SMOKE_QUESTION, user_id="smoke-test")
    answer = final_text(events)
    print(f"Tools called: {tool_calls(events)}")
    print(f"Answer: {answer}")
    if not answer:
        raise SystemExit("Smoke test failed: the agent returned no text.")


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("release")
    sub.add_parser("status")
    sub.add_parser("latest")
    sub.add_parser("rollback")
    p = sub.add_parser("canary")
    p.add_argument("--revision", required=True)
    p.add_argument("--percent", type=int, default=10)
    p = sub.add_parser("promote")
    p.add_argument("--revision", required=True)
    p = sub.add_parser("gateway")
    p.add_argument("--egress", required=True, help="Agent Gateway name or full resource name.")
    p = sub.add_parser("smoke")
    p.add_argument("--revision", help="Revision ID; omit to query the engine (traffic split applies).")
    args = parser.parse_args(argv)

    env = os.environ
    if args.command == "smoke":
        kind = "revision" if args.revision else "engine"
        asyncio.run(cmd_smoke(target_from_env(kind, args.revision, env)))
        return

    target = target_from_env("engine", env=env)
    client = platform_client(target.project_id, target.region)
    try:
        if args.command == "release":
            cmd_release(target, client, env)
        elif args.command == "status":
            cmd_status(target, client)
        elif args.command == "gateway":
            cmd_gateway(target, client, args.egress)
        elif args.command == "latest":
            _apply_always_latest(client, target.engine_name)
            print("Traffic mode: always latest.")
        else:
            cmd_set(target, client, args.command, getattr(args, "revision", None), getattr(args, "percent", 0))
    except traffic.TrafficError as exc:
        raise SystemExit(f"error: {exc}") from exc


if __name__ == "__main__":
    sys.exit(main())
