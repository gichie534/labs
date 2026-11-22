"""Traffic-split arithmetic for Agent Runtime revisions. Pure functions, no API calls.

A split is ``{revision_name: percent}`` with integer percents summing to 100. The platform also has an
"always latest" mode; `current_split` turns it into an explicit split so the rest of the code has one shape.
"""

import datetime as dt
from collections.abc import Iterable, Mapping
from dataclasses import dataclass

ACTIVE = "ACTIVE"


@dataclass(frozen=True)
class Revision:
    name: str
    state: str
    create_time: dt.datetime

    @property
    def short_id(self) -> str:
        return self.name.rsplit("/", 1)[-1]


class TrafficError(ValueError):
    """A requested traffic change is impossible (unknown revision, nothing to roll back to, ...)."""


def active(revisions: Iterable[Revision]) -> list[Revision]:
    """Active revisions, oldest first."""
    # The enum may be reported as "ACTIVE" or with a prefix ("STATE_ACTIVE"); "INACTIVE" must not match.
    return sorted(
        (r for r in revisions if r.state.upper().rsplit("_", 1)[-1] == ACTIVE),
        key=lambda r: r.create_time,
    )


def current_split(manual_targets: Mapping[str, int] | None, revisions: Iterable[Revision]) -> dict[str, int]:
    """The effective split: the manual targets, or 100% on the newest active revision ("always latest")."""
    if manual_targets:
        return {name: int(p) for name, p in manual_targets.items() if int(p) > 0}
    act = active(revisions)
    return {act[-1].name: 100} if act else {}


def primary(split: Mapping[str, int]) -> str | None:
    """The revision receiving the most traffic (ties: lexicographically last, i.e. usually newest ID)."""
    if not split:
        return None
    return max(split.items(), key=lambda kv: (kv[1], kv[0]))[0]


def validate(split: Mapping[str, int]) -> dict[str, int]:
    """Drop zero entries and check the split sums to 100."""
    cleaned = {k: int(v) for k, v in split.items() if int(v) > 0}
    if any(v < 0 or v > 100 for v in cleaned.values()):
        raise TrafficError(f"percents must be between 0 and 100: {split}")
    if sum(cleaned.values()) != 100:
        raise TrafficError(f"percents must sum to 100, got {sum(cleaned.values())}: {split}")
    return cleaned


def pin(revision: str) -> dict[str, int]:
    """All traffic to one revision."""
    return {revision: 100}


def canary(split: Mapping[str, int], candidate: str, percent: int) -> dict[str, int]:
    """Send ``percent`` to ``candidate`` and the rest to the current stable revision."""
    if not 0 < percent < 100:
        raise TrafficError("canary percent must be between 1 and 99; use promote for 100")
    stable = primary({k: v for k, v in split.items() if k != candidate})
    if stable is None:
        raise TrafficError("no stable revision to split with; promote the candidate instead")
    return validate({stable: 100 - percent, candidate: percent})


def rollback(split: Mapping[str, int], revisions: Iterable[Revision]) -> dict[str, int]:
    """Move all traffic back to the previous stable revision.

    During a canary (two or more targets) that is the oldest target, i.e. the one the canary was split from.
    After a promotion (single target) it is the newest active revision older than the current one.
    """
    act = active(revisions)
    created = {r.name: r.create_time for r in act}
    targets = [name for name in split if name in created]
    if len(targets) >= 2:
        return pin(min(targets, key=lambda n: created[n]))
    current = primary(split)
    if current is None or current not in created:
        raise TrafficError("no current revision found to roll back from")
    older = [r for r in act if r.create_time < created[current]]
    if not older:
        raise TrafficError(f"{current} is the oldest active revision; nothing to roll back to")
    return pin(older[-1].name)


def newest(revisions: Iterable[Revision], exclude: Iterable[str] = ()) -> Revision | None:
    """The most recently created active revision not in ``exclude``."""
    skip = set(exclude)
    act = [r for r in active(revisions) if r.name not in skip]
    return act[-1] if act else None
