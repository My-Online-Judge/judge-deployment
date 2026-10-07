import json

from oj_analyze import compare
from oj_analyze.__main__ import main


def write_run(tmp_path, name, run, results, events=(), alerts=()):
    d = tmp_path / name
    (d / "series").mkdir(parents=True)
    (d / "run.json").write_text(json.dumps(run))
    (d / "results.json").write_text(json.dumps(results))
    (d / "k6.log").write_text("\n".join(
        json.dumps({"level": "info", "msg": json.dumps(e), "source": "console", "time": "t"}) for e in events))
    rows = ["series,t,value"] + [f"alertname={a},{t},1" for a, t in alerts]
    (d / "series" / "alerts.csv").write_text("\n".join(rows) + "\n")
    return d


def req(t, ms, route):
    return {"ev": "req", "route": route, "status": 200, "t": t, "ms": ms}


def c6_run(tmp_path, name, during_ms, alert_s=None):
    run = {"id": name, "exp": "e4", "args": {"fault": "c6"}, "fault": {"inject_ms": 60_000, "remove_ms": 120_000}}
    routes = ("problem_list", "submit")
    events = [req(t, 10, r) for r in routes for t in range(0, 60_000, 1000)]
    events += [req(t, during_ms, r) for r in routes for t in range(60_000, 120_000, 1000)]
    events += [req(t, 10, r) for r in routes for t in range(120_000, 180_000, 1000)]
    results = {"fault": "c6", "routes": {r: {"error_rate_during": 0.0} for r in routes},
               "alerts_after_s": {} if alert_s is None else {"alertname=RedisUnavailable": alert_s},
               "invariant_ok": True, "system_errors": 0}
    return write_run(tmp_path, name, run, results, events)


def e3_run(tmp_path, name, p95, alerts=()):
    results = {"routes": {r: {"p50": p95 / 2, "p95": p95} for r in ("problem_list", "problem_detail", "history", "submit")}}
    return write_run(tmp_path, name, {"id": name, "exp": "e3", "args": {}}, results, alerts=alerts)


def test_e4_shows_each_figure_before_and_after(tmp_path):
    out = compare.write("e4", [c6_run(tmp_path, "b1", 615)], [c6_run(tmp_path, "a1", 12, alert_s=25)])
    assert "| c6 | problem_list | 0.0 → 0.0 | 615 → 12 | 605 → 2 | 0 → 0 |" in out
    assert "| c6 | — → 25 | — → — | — → — |" in out
    assert "- PASS invariant held in 1/1 runs, 0 SYSTEM_ERROR" in out
    assert "- PASS c6: first alert ≤ 60 s after inject in every run (25)" in out
    assert "- PASS c6 problem_list: overhead < 20 ms (median 2)" in out
    assert "- PASS c6 submit: p95 during < 100 ms (median 12)" in out
    assert "- PASS c6 submit: latency recovery < 5 s in every run (0)" in out


def test_a_fault_without_an_alert_misses_the_detection_target(tmp_path):
    out = compare.write("e4", [c6_run(tmp_path, "b1", 615)], [c6_run(tmp_path, "a1", 12)])
    assert "- MISS c6: first alert ≤ 60 s after inject in every run (none)" in out


def test_e3_within_range_and_no_alert(tmp_path):
    before = [e3_run(tmp_path, f"b{i}", p) for i, p in enumerate((10, 12, 14))]
    after = [e3_run(tmp_path, f"a{i}", p) for i, p in enumerate((13, 15, 16))]
    out = compare.write("e3", before, after)
    assert "- PASS no alert fired in any run (none)" in out
    assert "| history | 6.0 (5.0–7.0) → 7.5 (6.5–8.0) | 12.0 (10.0–14.0) → 15.0 (13.0–16.0) | yes |" in out


def test_e3_an_alert_or_a_slower_route_is_a_miss(tmp_path):
    out = compare.write("e3", [e3_run(tmp_path, "b0", 10)], [e3_run(tmp_path, "a0", 20, alerts=[("KafkaUnreachable", 100)])])
    assert "- MISS no alert fired in any run (KafkaUnreachable)" in out
    assert "- MISS submit: median p50 and p95 ≤ 1.1 × SP5's highest run" in out


def test_the_cli_prints_the_comparison(tmp_path, capsys):
    b, a = e3_run(tmp_path, "b0", 10), e3_run(tmp_path, "a0", 10)
    assert main(["compare", "e3", "--before", str(b), "--after", str(a)]) == 0
    assert "| submit |" in capsys.readouterr().out
