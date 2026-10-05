"""Windows and fault timings (spec §3.3, §3.5). Times: ms for request events, epoch seconds for Prometheus points."""


def step_windows(schedule):
    """schedule.json of e2-capacity.js → [(rate, start_s, end_s)] in epoch seconds."""
    base = schedule["startMs"] / 1000
    return [(w["rate"], base + w["startS"], base + w["endS"]) for w in schedule["windows"]]


def _is_error(status):
    return not 200 <= status < 300


def fault_timings(events, inject_ms, remove_ms):
    """Per route, from bg-load.js request events. A request errs when its status is not 2xx (0 = timeout/refused)."""
    reqs = [e for e in events if e.get("ev") == "req"]
    out = {}
    for route in sorted({e["route"] for e in reqs}):
        evs = sorted((e["t"], e["status"]) for e in reqs if e["route"] == route)

        def rate(lo, hi):
            xs = [s for t, s in evs if lo <= t < hi]
            return sum(1 for s in xs if _is_error(s)) / len(xs) if xs else None

        errors_from_inject = [t for t, s in evs if t >= inject_ms and _is_error(s)]
        ok_after = [t for t, s in evs if t >= remove_ms and not _is_error(s)]
        errors_after = [t for t, s in evs if t >= remove_ms and _is_error(s)]
        out[route] = {
            "error_rate_before": rate(float("-inf"), inject_ms),
            "error_rate_during": rate(inject_ms, remove_ms),
            "error_rate_after": rate(remove_ms, float("inf")),
            "first_error_after_inject_ms": min(errors_from_inject) - inject_ms if errors_from_inject else None,
            "first_success_after_remove_ms": min(ok_after) - remove_ms if ok_after else None,
            "last_error_after_remove_ms": max(errors_after) - remove_ms if errors_after else None,
        }
    return out


def queue_recovery_s(points, inject_s, remove_s):
    """Seconds after removal until the queue depth is back at or below its highest value in the minute before inject."""
    before = [v for t, v in points if inject_s - 60 <= t < inject_s and v is not None]
    if not before:
        return None
    level = max(before)
    for t, v in points:
        if t >= remove_s and v is not None and v <= level:
            return t - remove_s
    return None


def first_at_least(points, t0, threshold):
    for t, v in points:
        if t >= t0 and v is not None and v >= threshold:
            return t - t0
    return None
