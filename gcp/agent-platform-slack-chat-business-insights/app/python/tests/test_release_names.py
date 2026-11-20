import datetime as dt

from lifecycle import release


class _Obj:
    def __init__(self, **kw):
        self.__dict__.update(kw)


ENGINE = "projects/acme/locations/us-central1/reasoningEngines/123"


def _client(traffic_revision: str, listed_revision: str) -> _Obj:
    target = _Obj(runtime_revision_name=traffic_revision, percent=100)
    engine = _Obj(traffic_config=_Obj(traffic_split_manual=_Obj(targets=[target])))
    created = dt.datetime(2026, 1, 1, tzinfo=dt.UTC)
    revision = _Obj(api_resource=_Obj(name=listed_revision, state="ACTIVE", create_time=created))
    runtimes = _Obj(get=lambda name: _Obj(api_resource=engine), revisions=_Obj(list=lambda name: [revision]))
    return _Obj(runtimes=runtimes)


def test_revision_names_match_whether_the_api_uses_project_id_or_number():
    """revisions.list names revisions by project ID, the traffic config by project number."""
    client = _client(
        traffic_revision="projects/555/locations/us-central1/reasoningEngines/123/runtimeRevisions/2",
        listed_revision=f"{ENGINE}/runtimeRevisions/2",
    )
    split = release._manual_targets(client, ENGINE)
    names = [r.name for r in release._revisions(client, ENGINE)]
    assert split == {f"{ENGINE}/runtimeRevisions/2": 100}
    assert list(split) == names
