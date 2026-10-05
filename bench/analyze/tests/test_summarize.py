import json

from oj_analyze import summarize
from oj_analyze.__main__ import main


def put(results, name, run, res):
    d = results / name
    d.mkdir()
    (d / "run.json").write_text(json.dumps(run))
    (d / "results.json").write_text(json.dumps(res))


def step(rate, thr, p95, sat=False, lag=0.0):
    return {"rate": rate, "throughput": thr, "p95": p95, "p50": 1.0, "p99": None, "n": 100, "arrivals": 100,
            "queue_start": 0, "queue_end": 0, "saturated": sat, "verdict_lag_max": lag}


def test_cell_is_median_and_spread_or_a_dash():
    assert summarize.cell([1.0, 3.0, 2.0]) == "2.0 (1.0–3.0)"
    assert summarize.cell([2.0]) == "2.0"
    assert summarize.cell([None, None]) == "—"
    assert summarize.cell([0.001, 0.003], scale=100, digits=2) == "0.20 (0.10–0.30)"


def test_e2_summary_capacity_and_chart_skip_pilots_and_smoke(tmp_path):
    for k, thr in enumerate((1.9, 2.1, 2.0)):
        put(tmp_path, f"r{k}-e2-w1", {"exp": "e2", "args": {"workers": 1, "steps": [1, 2]}},
            {"steps": [step(1, 1.0, 2.0), step(2, thr, 9.0, sat=True, lag=4.0)]})
    put(tmp_path, "pilot-e2-w1", {"exp": "e2", "args": {"workers": 1, "pilot": True}}, {"steps": [step(8, 99.0, 1.0)]})
    put(tmp_path, "smoke-run", {"exp": "e2", "smoke": True, "args": {"workers": 1}}, {"steps": [step(8, 99.0, 1.0)]})
    path = summarize.write(tmp_path, "e2")
    text = open(path).read()
    assert "Runs: 3." in text and "| 1 | 2 |" in text
    assert "| 1 | 2.00 | 1 |" in text   # capacity 2.00, the 2/s step saturated in every run
    assert json.loads((tmp_path / "e2-capacity.json").read_text()) == {"1": 2.0}
    assert (tmp_path / "capacity.png").read_bytes()[:4] == b"\x89PNG"


def test_lag_threshold_uses_unsaturated_e2_steps_and_e3(tmp_path):
    put(tmp_path, "a", {"exp": "e2", "args": {"workers": 1}}, {"steps": [step(1, 1.0, 2.0, lag=3.0), step(2, 2.0, 9.0, sat=True, lag=400.0)]})
    put(tmp_path, "b", {"exp": "e3", "args": {}}, {"verdict_lag_max": 6.0})
    assert summarize.lag_threshold(tmp_path) == 12


def test_e4_summary_has_a_row_per_fault_and_route(tmp_path):
    for k in range(2):
        put(tmp_path, f"r{k}", {"exp": "e4", "args": {"fault": "c1"}},
            {"fault": "c1", "invariant_ok": k == 0, "queue_recovery_s": 30.0, "breaker_open_after_s": 4.0,
             "alerts_after_s": {"alertname=CircuitOpen": 40.0},
             "routes": {"submit": {"error_rate_during": 1.0, "first_error_after_inject_ms": 500, "first_success_after_remove_ms": 40000}}})
    text = open(summarize.write(tmp_path, "e4")).read()
    assert "| c1 | submit | 100.0 (100.0–100.0) |" in text
    assert "CircuitOpen 40 (40–40)" in text and "| 1/2 |" in text


def test_the_steps_command_prints_the_measured_step_list(tmp_path, capsys):
    d = tmp_path / "pilot"
    d.mkdir()
    (d / "results.json").write_text(json.dumps({"steps": [step(0.5, 0.5, 1.0), step(4, 2.0, 30.0, sat=True)]}))
    assert main(["steps", str(d)]) == 0
    assert capsys.readouterr().out.strip() == "1,1.5,2,2.5"
