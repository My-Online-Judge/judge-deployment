import json

from oj_analyze import export


class FakeProm:
    """Answers by query text; record the queries to check what the export asked."""

    def __init__(self, instant=None, ranges=None, vectors=None):
        self.instant, self.ranges, self.vectors, self.asked = instant or {}, ranges or {}, vectors or {}, []

    def query(self, q, at):
        self.asked.append(q)
        for key, value in self.instant.items():
            if key in q:
                return value(at) if callable(value) else value
        return None

    def vector(self, q, at):
        return self.vectors.get(q, {})

    def range(self, q, start, end, step=5):
        return self.ranges.get(q, {})


def k6_line(event):
    return json.dumps({"level": "info", "msg": json.dumps(event), "source": "console", "time": "t"})


def write_run(tmp_path, run, events=(), summary=None, schedule=None):
    d = tmp_path / run["id"]
    d.mkdir()
    (d / "run.json").write_text(json.dumps(run))
    (d / "k6.log").write_text("\n".join(k6_line(e) for e in events))
    (d / "summary.json").write_text(json.dumps(summary or {"metrics": {}}))
    if schedule:
        (d / "schedule.json").write_text(json.dumps(schedule))
    return d


def test_e2_steps_come_from_the_windows_and_the_histogram(tmp_path):
    run = {"id": "r-e2", "exp": "e2", "args": {"steps": [0.5, 1], "step_s": 180, "workers": 1}, "started_at": 1000, "ended_at": 1500}
    schedule = {"startMs": 1_000_000, "stepS": 180, "windows": [{"rate": 0.5, "startS": 5, "endS": 185}, {"rate": 1, "startS": 190, "endS": 370}]}
    events = [{"ev": "accepted", "id": f"s{i}", "t": 1_010_000 + i * 1500} for i in range(90)]   # 90 inside window 1
    prom = FakeProm(instant={"oj_judge_latency_seconds_count": 90.0, "histogram_quantile(0.5": 1.5, "histogram_quantile(0.95": 2.0,
                             "histogram_quantile(0.99": 2.5, "max_over_time": 0.0,
                             "max(oj_queue_depth)": lambda at: 1.0 if at > 1100 else 0.0})
    d = write_run(tmp_path, run, events, schedule=schedule)
    res = export.export_run(d, prom)
    first = res["steps"][0]
    assert first["rate"] == 0.5 and first["arrivals"] == 90 and first["throughput"] == 0.5
    assert first["p95"] == 2.0 and first["p99"] is None    # n = 90 < 500
    assert first["saturated"] is False and first["queue_end"] == 1.0
    assert res["verdicts_counted"] == 90.0
    assert json.loads((d / "results.json").read_text())["steps"][1]["arrivals"] == 0
    assert (d / "series" / "queue_depth.csv").exists() and (d / "queue_depth.png").exists()


def test_e1_route_figures_come_from_the_measure_sub_metrics(tmp_path):
    m = {"http_req_duration{phase:measure,route:history}": {"values": {"med": 12.0, "p(95)": 30.0, "p(99)": 50.0, "count": 9000}},
         "http_req_failed{phase:measure,route:history}": {"values": {"rate": 0.001}}}
    run = {"id": "r-e1", "exp": "e1", "args": {"rate": 50, "warmup_s": 60, "measure_s": 180}, "started_at": 1000, "ended_at": 1300}
    res = export.export_run(write_run(tmp_path, run, summary={"metrics": m}), FakeProm())
    assert res["routes"]["history"] == {"p50": 12.0, "p95": 30.0, "p99": 50.0, "n": 9000, "error_rate": 0.001}
    assert res["routes"]["problem_list"]["p50"] is None


def test_e4_fault_timings_and_recovery(tmp_path):
    run = {"id": "r-e4", "exp": "e4", "args": {"fault": "c1"}, "started_at": 900, "ended_at": 1400,
           "fault": {"inject_ms": 1_001_000, "remove_ms": 1_060_000}}
    events = [{"ev": "req", "route": "submit", "status": 200, "t": 990_000}, {"ev": "req", "route": "submit", "status": 503, "t": 1_002_000},
              {"ev": "req", "route": "submit", "status": 200, "t": 1_070_000}]
    queue = {"value": [(950.0, 2.0), (1000.0, 3.0), (1100.0, 9.0), (1200.0, 2.0)]}
    breaker = {"value": [(1000.0, 0.0), (1010.0, 1.0)]}
    alerts = {"alertname=ProblemServiceDown": [(1060.0, 1.0)]}
    from oj_analyze import promql
    prom = FakeProm(ranges={promql.QUEUE_DEPTH: queue, promql.BREAKER_OPEN: breaker, promql.ALERTS_FIRING: alerts})
    d = write_run(tmp_path, run, events)
    (d / "invariant.json").write_text(json.dumps({"ok": True}))
    res = export.export_run(d, prom)
    assert res["fault"] == "c1"
    assert res["routes"]["submit"]["first_error_after_inject_ms"] == 1000
    assert res["queue_recovery_s"] == 140.0 and res["breaker_open_after_s"] == 9.0
    assert res["alerts_after_s"] == {"alertname=ProblemServiceDown": 59.0}
    assert res["invariant_ok"] is True


def test_no_prometheus_data_at_all_still_exports(tmp_path):
    run = {"id": "r-e3", "exp": "e3", "args": {"submit_rate": 1, "read_rate": 20, "warmup_s": 60, "measure_s": 900},
           "started_at": 1000, "ended_at": 2000}
    res = export.export_run(write_run(tmp_path, run, [{"ev": "setup-done", "t": 1_000_000}]), FakeProm())
    assert res["judge_p95"] is None and res["heap_max_bytes"] == {}
