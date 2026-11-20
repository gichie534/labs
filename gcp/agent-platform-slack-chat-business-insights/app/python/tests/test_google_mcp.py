import asyncio
import datetime as dt

import pytest

from business_insights.tools import google_mcp


@pytest.mark.parametrize(
    ("url", "use_mtls", "expected"),
    [
        ("https://bigquery.googleapis.com/mcp", True, "https://bigquery.mtls.googleapis.com/mcp"),
        ("https://sqladmin.googleapis.com/mcp/readonly", True, "https://sqladmin.mtls.googleapis.com/mcp/readonly"),
        ("https://bigquery.googleapis.com/mcp", False, "https://bigquery.googleapis.com/mcp"),
        ("https://bigquery.mtls.googleapis.com/mcp", True, "https://bigquery.mtls.googleapis.com/mcp"),
        ("https://example.com/mcp", True, "https://example.com/mcp"),
    ],
)
def test_endpoint(url, use_mtls, expected):
    assert google_mcp.endpoint(url, use_mtls) == expected


def test_endpoint_respects_never(monkeypatch):
    monkeypatch.setenv("GOOGLE_API_USE_MTLS_ENDPOINT", "never")
    assert google_mcp.endpoint("https://bigquery.googleapis.com/mcp", True) == "https://bigquery.googleapis.com/mcp"


def test_no_client_certificate_locally(monkeypatch):
    monkeypatch.setenv("GOOGLE_API_USE_CLIENT_CERTIFICATE", "false")
    assert google_mcp.client_certificate_available() is False


class FakeCredentials:
    def __init__(self):
        self.valid = False
        self.token = None
        self.refreshes = 0

    def refresh(self, _request):
        self.refreshes += 1
        self.valid = True
        self.token = f"token-{self.refreshes}"


def test_adc_headers_refresh_only_when_needed():
    creds = FakeCredentials()
    provider = google_mcp.AdcHeaders("billing-project", credentials=creds)
    first = asyncio.run(provider(None))
    second = asyncio.run(provider(None))
    assert first == {"Authorization": "Bearer token-1", "x-goog-user-project": "billing-project"}
    assert second == first
    assert creds.refreshes == 1
    creds.valid = False
    assert asyncio.run(provider(None))["Authorization"] == "Bearer token-2"


class FakeResponse:
    def __init__(self, status, body):
        self.status_code, self._body, self.text = status, body, str(body)

    def json(self):
        return self._body


class FakeSession:
    def __init__(self, responses):
        self.responses, self.calls = list(responses), []

    def post(self, url, json, timeout):
        self.calls.append((url, json))
        return self.responses.pop(0)


T0 = dt.datetime(2026, 11, 18, 12, 0, tzinfo=dt.UTC)


def minted(token, expires):
    return FakeResponse(200, {"accessToken": token, "expireTime": expires.isoformat().replace("+00:00", "Z")})


@pytest.mark.parametrize(
    ("use_mtls", "host"), [(False, "iamcredentials.googleapis.com"), (True, "iamcredentials.mtls.googleapis.com")]
)
def test_impersonated_headers_mint_cache_and_refresh(use_mtls, host):
    session = FakeSession(
        [minted("sa-token-1", T0 + dt.timedelta(hours=1)), minted("sa-token-2", T0 + dt.timedelta(hours=2))]
    )
    clock = {"now": T0}
    provider = google_mcp.ImpersonatedHeaders(
        "bi-crm-reader@p.iam.gserviceaccount.com",
        "p",
        session_factory=lambda: (session, use_mtls),
        now=lambda: clock["now"],
    )

    assert asyncio.run(provider(None)) == {"Authorization": "Bearer sa-token-1", "x-goog-user-project": "p"}
    url, body = session.calls[0]
    assert (
        url
        == f"https://{host}/v1/projects/-/serviceAccounts/bi-crm-reader@p.iam.gserviceaccount.com:generateAccessToken"
    )
    assert body == {"scope": [google_mcp.CLOUD_PLATFORM], "lifetime": "3600s"}

    clock["now"] = T0 + dt.timedelta(minutes=50)  # still valid -> cached
    assert provider.headers()["Authorization"] == "Bearer sa-token-1"
    clock["now"] = T0 + dt.timedelta(minutes=56)  # inside the 5-minute margin -> re-mint
    assert provider.headers()["Authorization"] == "Bearer sa-token-2"
    assert len(session.calls) == 2


def test_impersonation_denied_is_a_clear_error():
    session = FakeSession([FakeResponse(403, {"error": {"message": "iam.serviceAccounts.getAccessToken denied"}})])
    provider = google_mcp.ImpersonatedHeaders(
        "sa@p.iam.gserviceaccount.com", "p", session_factory=lambda: (session, False)
    )
    with pytest.raises(PermissionError, match="getAccessToken"):
        provider.headers()


def test_toolsets_expose_only_read_only_tools():
    bq = google_mcp.bigquery_toolset("p")
    sql = google_mcp.cloudsql_toolset("p", "bi-crm-reader@p.iam.gserviceaccount.com")
    assert "execute_sql" not in google_mcp.BIGQUERY_TOOLS
    assert google_mcp.CLOUDSQL_TOOLS == ["execute_sql_readonly"]
    assert bq.tool_name_prefix == "bigquery"
    assert sql.tool_name_prefix == "cloudsql"
    # BigQuery is called as the agent; Cloud SQL as the borrowed service account.
    assert isinstance(bq.header_provider, google_mcp.AdcHeaders)
    assert isinstance(sql.header_provider, google_mcp.ImpersonatedHeaders)
