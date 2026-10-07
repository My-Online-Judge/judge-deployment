"""Windows and fault timings (spec §3.3, §3.5). Times: ms for request events, epoch seconds for Prometheus points."""
import math


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


def latency_windows(events, width_s=60, q=0.95):
    """Per route, the q-quantile (nearest rank) of the logged request durations, ms, in consecutive width_s windows:
    [(window end, epoch s, value)]. Client latency over time (spec §3.4) — k6's remote-written trend stats are
    cumulative since the start of the run and cannot show it."""
    reqs = [e for e in events if e.get("ev") == "req" and e.get("ms") is not None]
    if not reqs:
        return {}
    t0 = min(e["t"] for e in reqs)
    out = {}
    for route in sorted({e["route"] for e in reqs}):
        buckets = {}
        for e in reqs:
            if e["route"] == route:
                buckets.setdefault(int((e["t"] - t0) // (width_s * 1000)), []).append(e["ms"])
        pts = []
        for k in sorted(buckets):
            xs = sorted(buckets[k])
            pts.append((t0 / 1000 + (k + 1) * width_s, xs[max(1, math.ceil(q * len(xs))) - 1]))
        out[route] = pts
    return out


def _quantile(xs, q):
    """Nearest-rank q-quantile of a non-empty list, as latency_windows computes it."""
    xs = sorted(xs)
    return xs[max(1, math.ceil(q * len(xs))) - 1]


def _latency(xs):
    return {"p50": _quantile(xs, 0.5), "p95": _quantile(xs, 0.95), "n": len(xs)} if xs else {"p50": None, "p95": None, "n": 0}


def fault_latency(events, inject_ms, remove_ms, window_s=5):
    """Per route, client latency around a fault (sub-project 6 §3.3), ms: p50/p95/n in the minute before the injection
    and during the fault; overhead_p95 = during − before; recovery_s = the end, in seconds after the removal, of the
    last window_s window whose p95 is above twice the p95 before or 100 ms, whichever is larger (0 when none is)."""
    reqs = [e for e in events if e.get("ev") == "req" and e.get("ms") is not None]
    out = {}
    for route in sorted({e["route"] for e in reqs}):
        rs = [(e["t"], e["ms"]) for e in reqs if e["route"] == route]
        before = _latency([ms for t, ms in rs if inject_ms - 60_000 <= t < inject_ms])
        during = _latency([ms for t, ms in rs if inject_ms <= t < remove_ms])
        recovery = None
        if before["p95"] is not None:
            limit = max(2 * before["p95"], 100)
            windows = {}
            for t, ms in rs:
                if t >= remove_ms:
                    windows.setdefault(int((t - remove_ms) // (window_s * 1000)), []).append(ms)
            slow = [k for k, xs in windows.items() if _quantile(xs, 0.95) > limit]
            recovery = (max(slow) + 1) * window_s if slow else 0
        out[route] = {"before": before, "during": during,
                      "overhead_p95": None if before["p95"] is None or during["p95"] is None else during["p95"] - before["p95"],
                      "recovery_s": recovery}
    return out


def increase(points, t0, t1):
    """A counter's growth from t0 to t1 (epoch s) in range-query points; a series that did not exist yet counts as 0."""
    def at(t):
        vs = [v for ts, v in points if ts <= t and v is not None]
        return vs[-1] if vs else 0
    return at(t1) - at(t0)
