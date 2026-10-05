import json

from oj_analyze import summarize
from oj_analyze.__main__ import main


def put(results, name, run, res):
    d = results / name
    d.mkdir()
    (d / "run.json").write_text(json.dumps(run))
    (d / "results.json").write_text(json.dumps(res))


def step(rate, thr, p95, sat=False, lag=0.0, censored=False):
    return {"rate": rate, "throughput": thr, "p95": None if censored else p95, "p50": 1.0, "p99": None, "n": 100,
            "arrivals": 100, "measured_rate": rate * 0.98, "queue_start": 0, "queue_end": 0, "saturated": sat,
            "verdict_lag_max": lag, "p50_censored": False, "p95_censored": censored, "p99_censored": censored,
            "histogram_top_s": 30.0}


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
    assert "| workers | target/s | measured/s | verdicts/s | p50 s | p95 s | p99 s | n | saturated runs |" in text
    assert "| 1 | 1 | 0.98 (0.98–0.98) |" in text
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


def test_a_censored_quantile_prints_as_at_least_the_histogram_top(tmp_path):
    put(tmp_path, "c1", {"exp": "e2", "args": {"workers": 1}}, {"steps": [step(4, 1.2, 30.0, sat=True, censored=True)]})
    text = open(summarize.write(tmp_path, "e2")).read()
    assert "≥ 30" in text and "30.00" not in text


def test_system_errors_and_dropped_iterations_reach_the_tables(tmp_path):
    for k in range(2):
        put(tmp_path, f"e{k}", {"exp": "e4", "args": {"fault": "c2"}},
            {"fault": "c2", "invariant_ok": True, "system_errors": 3 + k, "dropped_iterations": k,
             "routes": {"submit": {"error_rate_during": 0.0}}})
    text = open(summarize.write(tmp_path, "e4")).read()
    assert "SYSTEM_ERROR" in text and "3.5 (3.0–4.0)" in text
    assert "Runs with dropped iterations: 1 of 2" in text


def test_e3_prints_n_beside_every_percentile(tmp_path):
    put(tmp_path, "x", {"exp": "e3", "args": {}},
        {"routes": {"history": {"p50": 5.0, "p95": 9.0, "p99": None, "n": 18000, "error_rate": 0.0}},
         "judge_p95": 2.0, "judge_n": 450.0, "system_errors": 0})
    text = open(summarize.write(tmp_path, "e3")).read()
    assert "| route | p50 ms | p95 ms | p99 ms | n | errors % |" in text and "| history | 5.0 | 9.0 | — | 18000 |" in text
    assert "| judge latency p95, s (n) | 2.00 (450) |" in text
