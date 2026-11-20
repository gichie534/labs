"""Toolsets for Google-managed remote MCP servers (BigQuery, Cloud SQL).

On Agent Runtime the process runs as its **Agent Identity**: Application Default Credentials return tokens for
``principal://agents.global.../reasoningEngines/<id>``, bound to the runtime's mTLS client certificate
(Context-Aware Access). Such a token is only accepted over an mTLS connection, so:

- the endpoint is switched to its ``.mtls.googleapis.com`` form when a client certificate is available, and ADK's
  MCP session manager then opens the connection with that certificate;
- locally there is no certificate: the same code talks to the plain endpoint with the developer's ADC token.

The two toolsets authenticate differently:

- **BigQuery** is called as the agent itself (`AdcHeaders`).
- **Cloud SQL** is called as the ``bi-crm-reader`` service account (`ImpersonatedHeaders`). Cloud SQL IAM database
  authentication logs in as the caller of the Data API, and it accepts users and service accounts but not Agent
  Identity principals. So the agent uses its own identity to mint a short-lived token for that one account (IAM
  Credentials ``generateAccessToken``) and sends it to the Cloud SQL MCP server. No password exists anywhere.
"""

from __future__ import annotations

import asyncio
import datetime as dt
import os
import threading
from collections.abc import Callable
from typing import Any
from urllib.parse import quote, urlsplit, urlunsplit

import google.auth
from google.adk.tools.mcp_tool import McpToolset, StreamableHTTPConnectionParams
from google.auth.transport.requests import AuthorizedSession, Request

BIGQUERY_MCP_URL = "https://bigquery.googleapis.com/mcp"
# The read-only toolset endpoint: execute_sql (read-write) is not even listed there.
CLOUDSQL_READONLY_MCP_URL = "https://sqladmin.googleapis.com/mcp/readonly"
IAM_CREDENTIALS_URL = (
    "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/{account}:generateAccessToken"
)

# Only the tools the agent needs. Everything else the servers offer stays invisible to the model.
BIGQUERY_TOOLS = ["execute_sql_readonly", "get_query_results", "list_table_ids", "get_table_info"]
CLOUDSQL_TOOLS = ["execute_sql_readonly"]

# Prefixes keep the two `execute_sql_readonly` tools apart for the model and for callbacks.
BIGQUERY_PREFIX = "bigquery"
CLOUDSQL_PREFIX = "cloudsql"

CLOUD_PLATFORM = "https://www.googleapis.com/auth/cloud-platform"
# Borrowed tokens live for an hour at most; refresh well before that.
_TOKEN_LIFETIME = "3600s"
_REFRESH_MARGIN = dt.timedelta(minutes=5)


def client_certificate_available() -> bool:
    """True when google-auth would present a client certificate (Agent Identity on Agent Runtime)."""
    try:
        from google.auth.transport import mtls

        use_cert = bool(mtls.should_use_client_cert())
    except (ImportError, AttributeError):
        use_cert = os.getenv("GOOGLE_API_USE_CLIENT_CERTIFICATE", "false").lower() == "true"
    if not use_cert:
        return False
    try:
        from google.auth.transport import mtls

        return bool(mtls.has_default_client_cert_source())
    except Exception:  # noqa: BLE001 - a missing cert source just means "no mTLS"
        return False


def endpoint(url: str, use_mtls: bool) -> str:
    """Return ``url``, rewritten to its ``*.mtls.googleapis.com`` host when ``use_mtls`` is set."""
    if not use_mtls or os.getenv("GOOGLE_API_USE_MTLS_ENDPOINT", "auto").lower() == "never":
        return url
    parts = urlsplit(url)
    host = parts.hostname or ""
    if not host.endswith(".googleapis.com") or host.endswith(".mtls.googleapis.com"):
        return url
    mtls_host = host[: -len(".googleapis.com")] + ".mtls.googleapis.com"
    netloc = f"{mtls_host}:{parts.port}" if parts.port else mtls_host
    return urlunsplit((parts.scheme, netloc, parts.path, parts.query, parts.fragment))


class AdcHeaders:
    """MCP header provider: the caller's own ADC bearer token plus the quota project."""

    def __init__(self, quota_project: str, credentials: Any = None) -> None:
        self._quota_project = quota_project
        self._credentials = credentials
        self._lock = threading.Lock()

    def headers(self) -> dict[str, str]:
        with self._lock:
            if self._credentials is None:
                self._credentials, _ = google.auth.default(scopes=[CLOUD_PLATFORM])
            if not self._credentials.valid:
                self._credentials.refresh(Request())
            token = self._credentials.token
        return {"Authorization": f"Bearer {token}", "x-goog-user-project": self._quota_project}

    async def __call__(self, _context: Any = None) -> dict[str, str]:
        # Token refresh is a blocking HTTP call; keep it off the event loop.
        return await asyncio.to_thread(self.headers)


def _default_session() -> tuple[Any, bool]:
    """An HTTP session authorized as the caller (ADC), over mTLS when a client certificate is available."""
    credentials, _ = google.auth.default(scopes=[CLOUD_PLATFORM])
    session = AuthorizedSession(credentials)
    use_mtls = client_certificate_available()
    if use_mtls:
        session.configure_mtls_channel()
    return session, use_mtls


class ImpersonatedHeaders:
    """MCP header provider: a short-lived token for ``service_account``, minted with the caller's identity.

    The caller needs ``iam.serviceAccounts.getAccessToken`` on that account (roles/iam.serviceAccountTokenCreator).
    Tokens are cached and re-minted five minutes before they expire. Every mint is an audit log entry in the
    IAM Credentials API naming both the caller (the agent) and the account.
    """

    def __init__(
        self,
        service_account: str,
        quota_project: str,
        session_factory: Callable[[], tuple[Any, bool]] = _default_session,
        now: Callable[[], dt.datetime] = lambda: dt.datetime.now(dt.UTC),
    ) -> None:
        self._service_account = service_account
        self._quota_project = quota_project
        self._session_factory = session_factory
        self._now = now
        self._session: tuple[Any, bool] | None = None
        self._token: str | None = None
        self._expires: dt.datetime | None = None
        self._lock = threading.Lock()

    def _mint(self) -> None:
        if self._session is None:
            self._session = self._session_factory()
        session, use_mtls = self._session
        url = endpoint(IAM_CREDENTIALS_URL.format(account=quote(self._service_account, safe="@.")), use_mtls)
        response = session.post(url, json={"scope": [CLOUD_PLATFORM], "lifetime": _TOKEN_LIFETIME}, timeout=30)
        if response.status_code != 200:
            raise PermissionError(
                f"could not mint a token for {self._service_account}: HTTP {response.status_code} {response.text[:300]}"
            )
        body = response.json()
        self._token = body["accessToken"]
        self._expires = dt.datetime.fromisoformat(body["expireTime"].replace("Z", "+00:00"))

    def headers(self) -> dict[str, str]:
        with self._lock:
            if self._token is None or self._expires is None or self._now() >= self._expires - _REFRESH_MARGIN:
                self._mint()
            token = self._token
        return {"Authorization": f"Bearer {token}", "x-goog-user-project": self._quota_project}

    async def __call__(self, _context: Any = None) -> dict[str, str]:
        return await asyncio.to_thread(self.headers)


def _toolset(url: str, tools: list[str], prefix: str, header_provider: Any) -> McpToolset:
    return McpToolset(
        connection_params=StreamableHTTPConnectionParams(
            url=endpoint(url, client_certificate_available()),
            timeout=30.0,
            sse_read_timeout=120.0,
        ),
        tool_filter=tools,
        tool_name_prefix=prefix,
        header_provider=header_provider,
    )


def bigquery_toolset(project_id: str) -> McpToolset:
    """Read-only BigQuery tools, called as the agent: query, poll long queries, list tables, describe a table."""
    return _toolset(BIGQUERY_MCP_URL, BIGQUERY_TOOLS, BIGQUERY_PREFIX, AdcHeaders(project_id))


def cloudsql_toolset(project_id: str, reader_service_account: str) -> McpToolset:
    """Read-only Cloud SQL tool, called as ``reader_service_account`` (Cloud SQL IAM database authentication)."""
    return _toolset(
        CLOUDSQL_READONLY_MCP_URL,
        CLOUDSQL_TOOLS,
        CLOUDSQL_PREFIX,
        ImpersonatedHeaders(reader_service_account, project_id),
    )
