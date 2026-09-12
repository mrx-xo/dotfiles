"""Shared local-clock lighting schedule (including local DST transitions)."""
import datetime
import time

DAY_START_HOUR = 8
DAY_END_HOUR = 23


def next_boundary(now=None):
    """Epoch of the next 08:00 or 23:00 — where a manual override expires and
    the schedule takes back over."""
    now = now if now is not None else time.time()
    lt = datetime.datetime.fromtimestamp(now)
    best = None
    for h in (DAY_START_HOUR, DAY_END_HOUR):
        b = lt.replace(hour=h, minute=0, second=0, microsecond=0)
        if b <= lt:
            b += datetime.timedelta(days=1)
        best = b if best is None else min(best, b)
    return best.timestamp()
