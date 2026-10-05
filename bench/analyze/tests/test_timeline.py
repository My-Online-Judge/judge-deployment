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
