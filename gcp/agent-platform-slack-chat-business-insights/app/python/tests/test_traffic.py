import datetime as dt

import pytest

from lifecycle import traffic
from lifecycle.traffic import Revision, TrafficError

E = "projects/p/locations/l/reasoningEngines/1/runtimeRevisions/"


def rev(n, state="ACTIVE"):
    return Revision(name=E + str(n), state=state, create_time=dt.datetime(2026, 11, n, tzinfo=dt.UTC))


REVS = [rev(1), rev(2, "ARCHIVED"), rev(3), rev(4)]


def test_active_ignores_archived_and_inactive():
    revisions = [*REVS, rev(5, "INACTIVE"), rev(6, "STATE_ACTIVE")]
    assert [r.short_id for r in traffic.active(revisions)] == ["1", "3", "4", "6"]


def test_current_split_always_latest_means_newest_active():
    assert traffic.current_split(None, REVS) == {E + "4": 100}
    assert traffic.current_split({E + "3": 100, E + "4": 0}, REVS) == {E + "3": 100}
    assert traffic.current_split(None, []) == {}


def test_canary_splits_from_the_stable_revision():
    assert traffic.canary({E + "3": 100}, E + "4", 10) == {E + "3": 90, E + "4": 10}
    # Re-running a canary with a new percentage keeps the same stable revision.
    assert traffic.canary({E + "3": 90, E + "4": 10}, E + "4", 50) == {E + "3": 50, E + "4": 50}
    with pytest.raises(TrafficError):
        traffic.canary({E + "4": 100}, E + "4", 10)
    with pytest.raises(TrafficError):
        traffic.canary({E + "3": 100}, E + "4", 100)


def test_rollback_during_canary_returns_to_the_older_target():
    assert traffic.rollback({E + "3": 90, E + "4": 10}, REVS) == {E + "3": 100}


def test_rollback_after_promotion_returns_to_the_previous_active_revision():
    assert traffic.rollback({E + "4": 100}, REVS) == {E + "3": 100}
    with pytest.raises(TrafficError):
        traffic.rollback({E + "1": 100}, REVS)


def test_validate():
    assert traffic.validate({"a": 60, "b": 40, "c": 0}) == {"a": 60, "b": 40}
    with pytest.raises(TrafficError):
        traffic.validate({"a": 60, "b": 30})


def test_newest_excludes_known_revisions():
    assert traffic.newest(REVS, exclude=[E + "4"]).short_id == "3"
    assert traffic.newest(REVS, exclude=[r.name for r in REVS]) is None
