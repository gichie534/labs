from types import SimpleNamespace

from business_insights.tools import glossary


class FakeClient:
    def __init__(self):
        self.calls = 0

    def list_blobs(self, bucket, prefix):
        self.calls += 1
        assert (bucket, prefix) == ("docs-bucket", "docs/")
        return [
            SimpleNamespace(name="docs/periods.md", download_as_bytes=lambda: b"# Periods"),
            SimpleNamespace(name="docs/metrics.md", download_as_bytes=lambda: b"# Metrics"),
            SimpleNamespace(name="docs/image.png", download_as_bytes=lambda: b"\x89PNG"),
        ]


def test_reads_markdown_sorted_and_caches(monkeypatch):
    monkeypatch.setitem(glossary._cache, "docs", None)
    client = FakeClient()
    clock = iter([0.0, 10.0, 400.0, 400.0])
    load = lambda: glossary.load_documents("docs-bucket", lambda: client, now=lambda: next(clock))  # noqa: E731

    docs = load()
    assert [d["name"] for d in docs] == ["metrics.md", "periods.md"]
    load()
    assert client.calls == 1  # cached
    load()
    assert client.calls == 2  # expired


def test_tool_reports_errors_instead_of_raising(monkeypatch):
    def boom(*_args, **_kwargs):
        raise PermissionError("403 storage.objects.list")

    monkeypatch.setattr(glossary, "load_documents", boom)
    result = glossary.read_business_glossary()
    assert result["status"] == "error" and "403" in result["error"]
