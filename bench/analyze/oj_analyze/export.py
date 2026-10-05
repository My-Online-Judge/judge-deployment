"""One run directory → series/*.csv, *.png and results.json (spec §5)."""
import csv
import json
from pathlib import Path

from . import charts, promql, stats, timeline
from . import invariant as inv

READ_ROUTES = ["problem_list", "problem_detail", "history"]
CHARTS = [
    ("queue_depth", "Judge queue depth", "submissions"),
    ("throughput", "Verdicts per second", "verdicts/s"),
    ("judge_p95", "Judge latency p95 (submit → verdict)", "seconds"),
    ("k6_reqs", "Requests per second by route (k6)", "req/s"),
    ("heap", "JVM heap by service", "bytes"),
]


def write_csv(path, data):
    with open(path, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["series", "t", "value"])
        for key in sorted(data):
            for t, v in data[key]:
                w.writerow([key, f"{t:.0f}", "" if v is None else f"{v:.6g}"])


def summary_routes(summary, routes, phase="measure"):
    """Per route, the steady-window figures k6 computed (ms), from the phase/route sub-metrics."""
    m = summary.get("metrics", {})
    out = {}
    for r in routes:
        d = m.get(f"http_req_duration{{phase:{phase},route:{r}}}", {}).get("values", {})
        f = m.get(f"http_req_failed{{phase:{phase},route:{r}}}", {}).get("values", {})
        n = d.get("count")
        out[r] = {"p50": d.get("med"), "p95": d.get("p(95)"), "p99": stats.reportable_p99(d.get("p(99)"), n),
                  "n": n, "error_rate": f.get("rate")}
    return out


def e2_steps(run_dir, prom, events):
    schedule = json.loads((run_dir / "schedule.json").read_text())
    accepted_s = [e["t"] / 1000 for e in events if e.get("ev") == "accepted"]
    rows = []
    for rate, start, end in timeline.step_windows(schedule):
        w = int(round(end - start))
        n = prom.query(promql.verdict_count(w), end)
        arrivals = sum(1 for t in accepted_s if start <= t < end)
        q0, q1 = prom.query(promql.QUEUE_DEPTH, start), prom.query(promql.QUEUE_DEPTH, end)
        rows.append({
            "rate": rate, "arrivals": arrivals, "n": n, "throughput": None if n is None else n / w,
            "p50": prom.query(promql.judge_quantile(0.5, w), end),
            "p95": prom.query(promql.judge_quantile(0.95, w), end),
            "p99": stats.reportable_p99(prom.query(promql.judge_quantile(0.99, w), end), n),
            "queue_start": q0, "queue_end": q1, "saturated": stats.saturated(q0, q1, arrivals),
            "verdict_lag_max": prom.query(promql.max_over(promql.VERDICT_LAG, w), end),
        })
    return rows


def measure_window(run, events):
    """E3: [setup-done + warm-up, + measure] in epoch seconds; None without a setup-done event."""
    done = [e["t"] for e in events if e.get("ev") == "setup-done"]
    if not done:
        return None
    start = done[0] / 1000 + run["args"]["warmup_s"]
    return start, start + run["args"]["measure_s"]


def export_run(run_dir, prom):
    run_dir = Path(run_dir)
    run = json.loads((run_dir / "run.json").read_text())
    log = run_dir / "k6.log"
    events = inv.parse_k6_log(log.read_text().splitlines()) if log.exists() else []
    summary_path = run_dir / "summary.json"
    summary = json.loads(summary_path.read_text()) if summary_path.exists() else {}
    start = run["started_at"]
    end = run.get("ended_at") or run.get("load_ended_at") or start
    fault = run.get("fault") or {}
    shade = [(fault["inject_ms"] / 1000, fault["remove_ms"] / 1000)] if {"inject_ms", "remove_ms"} <= set(fault) else []

    series_dir = run_dir / "series"
    series_dir.mkdir(exist_ok=True)
    series = {}
    for name, q in promql.series_for(run["id"]).items():
        series[name] = prom.range(q, start, end)
        write_csv(series_dir / f"{name}.csv", series[name])
    for name, title, unit in CHARTS:
        charts.timeseries_png(run_dir / f"{name}.png", series[name], title, unit, start, shade)

    # Cross-check for the invariant (spec §5): verdicts the service applied while the run lasted.
    if run["exp"] in ("e3", "e4"):  # client latency over time, from the request log: 1-minute windows, 10 s around a fault
        latency = timeline.latency_windows(events, width_s=60 if run["exp"] == "e3" else 10)
        write_csv(series_dir / "client_p95.csv", latency)
        charts.timeseries_png(run_dir / "client_p95.png", latency, "Client latency p95 by route (request log)", "ms", start, shade)

    results = {"id": run["id"], "exp": run["exp"],
               "verdicts_counted": prom.query(promql.verdict_count(max(1, int(round(end - start)))), end)}
    if run["exp"] == "e1":
        results["routes"] = summary_routes(summary, READ_ROUTES)
    elif run["exp"] == "e2":
        results["steps"] = e2_steps(run_dir, prom, events)
    elif run["exp"] == "e3":
        results["routes"] = summary_routes(summary, READ_ROUTES + ["submit"])
        results.update(judge_p95=None, verdict_lag_max=None, outbox_age_max=None, heap_max_bytes={})
        window = measure_window(run, events)
        if window:
            w, at = int(round(window[1] - window[0])), window[1]
            results["judge_p95"] = prom.query(promql.judge_quantile(0.95, w), at)
            results["verdict_lag_max"] = prom.query(promql.max_over(promql.VERDICT_LAG, w), at)
            results["outbox_age_max"] = prom.query(promql.max_over(promql.OUTBOX_AGE, w), at)
            results["heap_max_bytes"] = prom.vector(promql.max_over(promql.HEAP_BY_JOB, w), at)
    elif run["exp"] == "e4" and shade:
        inject_s, remove_s = shade[0]
        results["fault"] = run["args"]["fault"]
        results["routes"] = timeline.fault_timings(events, fault["inject_ms"], fault["remove_ms"])
        results["queue_recovery_s"] = timeline.queue_recovery_s(series["queue_depth"].get("value", []), inject_s, remove_s)
        results["breaker_open_after_s"] = timeline.first_at_least(series["breaker_open"].get("value", []), inject_s, 1)
        results["alerts_after_s"] = {k: timeline.first_at_least(pts, inject_s, 1) for k, pts in series["alerts"].items()}
    inv_path = run_dir / "invariant.json"
    if inv_path.exists():
        results["invariant_ok"] = json.loads(inv_path.read_text())["ok"]
    (run_dir / "results.json").write_text(json.dumps(results, indent=1))
    return results
