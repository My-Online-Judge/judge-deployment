from oj_analyze import timeline


def ev(t, status, route="submit"):
    return {"ev": "req", "route": route, "status": status, "t": t}


def test_step_windows_are_absolute_epoch_seconds():
    sched = {"startMs": 1_000_000, "stepS": 180,
             "windows": [{"rate": 0.5, "startS": 5, "endS": 185}, {"rate": 1, "startS": 190, "endS": 370}]}
    assert timeline.step_windows(sched) == [(0.5, 1005.0, 1185.0), (1, 1190.0, 1370.0)]


def test_fault_timings_per_route():
    events = [ev(900, 200), ev(1000, 200), ev(1500, 503), ev(1900, 503), ev(2100, 503), ev(2600, 200), ev(2700, 200),
              {"ev": "accepted", "id": "x", "t": 1}]
    t = timeline.fault_timings(events, inject_ms=1200, remove_ms=2000)["submit"]
    assert t["error_rate_before"] == 0.0
    assert t["error_rate_during"] == 1.0
    assert abs(t["error_rate_after"] - 1 / 3) < 1e-9
    assert t["first_error_after_inject_ms"] == 300
    assert t["last_error_after_remove_ms"] == 100
    assert t["first_success_after_remove_ms"] == 600


def test_a_route_that_never_fails_has_no_error_times():
    t = timeline.fault_timings([ev(1300, 200, "history")], 1200, 2000)["history"]
    assert t["first_error_after_inject_ms"] is None
    assert t["error_rate_during"] == 0.0
    assert t["error_rate_before"] is None


def test_status_zero_a_timeout_is_an_error():
    assert timeline.fault_timings([ev(1300, 0)], 1200, 2000)["submit"]["error_rate_during"] == 1.0


def test_queue_recovery_counts_from_removal_back_to_the_pre_fault_level():
    pts = [(940, 2.0), (960, 3.0), (1000, 3.0), (1100, 40.0), (1200, 30.0), (1250, 3.0), (1300, 1.0)]
    assert timeline.queue_recovery_s(pts, inject_s=1001, remove_s=1060) == 190


def test_queue_recovery_is_none_without_a_baseline_or_without_recovery():
    assert timeline.queue_recovery_s([(1100, 40.0)], inject_s=1001, remove_s=1060) is None
    assert timeline.queue_recovery_s([(990, 1.0), (1100, 40.0), (1200, None)], inject_s=1001, remove_s=1060) is None


def test_first_at_least_is_seconds_after_t0():
    assert timeline.first_at_least([(10, 0.0), (20, 1.0), (30, 1.0)], 12, 1) == 8
    assert timeline.first_at_least([(10, 0.0)], 5, 1) is None


def test_latency_windows_give_a_per_window_quantile_per_route():
    evs = [{"ev": "req", "route": "history", "status": 200, "t": 1_000_000 + i * 1000, "ms": float(i % 60 + 1)} for i in range(120)]
    evs.append({"ev": "req", "route": "submit", "status": 200, "t": 1_000_000, "ms": 30.0})
    evs.append({"ev": "accepted", "id": "x", "t": 1})
    w = timeline.latency_windows(evs, width_s=60, q=0.95)
    assert w["history"] == [(1060.0, 57.0), (1120.0, 57.0)]
    assert w["submit"] == [(1060.0, 30.0)]
    assert timeline.latency_windows([], 60) == {}


def req(t, ms, route="submit", status=200):
    return {"ev": "req", "route": route, "status": status, "t": t, "ms": ms}


def test_fault_latency_before_during_and_overhead():
    events = [req(t, 10) for t in range(0, 60_000, 1000)] + [req(t, 2000) for t in range(60_000, 120_000, 1000)] \
             + [req(t, 10) for t in range(120_000, 180_000, 1000)]
    f = timeline.fault_latency(events, inject_ms=60_000, remove_ms=120_000)["submit"]
    assert f["before"] == {"p50": 10, "p95": 10, "n": 60}
    assert f["during"]["p95"] == 2000
    assert f["overhead_p95"] == 1990
    assert f["recovery_s"] == 0


def test_latency_recovery_is_the_end_of_the_last_slow_window_after_removal():
    events = [req(t, 10) for t in range(0, 60_000, 500)]
    events += [req(120_000 + t, 1000) for t in range(0, 12_000, 500)]     # slow for 12 s after the removal
    events += [req(120_000 + t, 10) for t in range(12_000, 60_000, 500)]
    f = timeline.fault_latency(events, inject_ms=60_000, remove_ms=120_000)["submit"]
    assert f["recovery_s"] == 15   # the windows [0,5), [5,10), [10,15) s are slow


def test_the_slow_threshold_is_at_least_100_ms():
    events = [req(t, 10) for t in range(0, 60_000, 500)] + [req(120_000 + t, 90) for t in range(0, 30_000, 500)]
    assert timeline.fault_latency(events, 60_000, 120_000)["submit"]["recovery_s"] == 0


def test_a_route_without_requests_before_the_fault_has_no_overhead_or_recovery():
    f = timeline.fault_latency([req(70_000, 5)], 60_000, 120_000)["submit"]
    assert f["before"]["p95"] is None and f["overhead_p95"] is None and f["recovery_s"] is None


def test_counter_increase_counts_a_series_that_did_not_exist_yet_from_zero():
    pts = [(105.0, 1.0), (110.0, 1.0), (130.0, 2.0)]
    assert timeline.increase(pts, 100, 125) == 1.0
    assert timeline.increase(pts, 100, 140) == 2.0
    assert timeline.increase([], 100, 140) == 0
