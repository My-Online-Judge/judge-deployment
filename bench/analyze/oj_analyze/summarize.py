"""The runs of one experiment → results/summary-<exp>.md: median (min–max) over the runs (spec §3.1).
Smoke runs and E2 pilots are not measurements and are left out. Every percentile has its n beside it; a judge-latency
quantile the histogram censors prints as "≥ <top>" (review C2); the measured load and SYSTEM_ERRORs are shown (I2/I3)."""
import json
from collections import defaultdict
from pathlib import Path

from . import charts, stats

READ_ROUTES = ["problem_list", "problem_detail", "history"]
TITLES = {"e1": "E1 — read latency", "e2": "E2 — judging capacity", "e3": "E3 — sustained mixed load", "e4": "E4 — resilience"}


def load(results_dir, exp):
    runs = []
    for d in sorted(p for p in Path(results_dir).iterdir() if p.is_dir() and p.name != "smoke"):
        if not ((d / "run.json").exists() and (d / "results.json").exists()):
            continue
        run = json.loads((d / "run.json").read_text())
        if run.get("exp") == exp and not run.get("smoke") and not run.get("args", {}).get("pilot"):
            runs.append((run, json.loads((d / "results.json").read_text())))
    return runs


def cell(values, scale=1.0, digits=1):
    s = stats.summarize([None if v is None else v * scale for v in values])
    if s is None:
        return "—"
    f = f"{{:.{digits}f}}"
    return f"{f.format(s['median'])} ({f.format(s['min'])}–{f.format(s['max'])})" if s["runs"] > 1 else f.format(s["median"])


def qcell(rows, key, digits=2):
    """A judge-latency quantile over the runs: "≥ <top>" when any run's value lay above the histogram's top bucket."""
    cut = [r for r in rows if r.get(f"{key}_censored")]
    if cut:
        return f"≥ {cut[0].get('histogram_top_s') or 30:g}"
    return cell([r.get(key) for r in rows], digits=digits)


def e1(runs):
    by = defaultdict(list)
    for run, res in runs:
        by[run["args"]["rate"]].append(res)
    lines = ["| req/s | route | p50 ms | p95 ms | p99 ms | n | errors % |", "|---|---|---|---|---|---|---|"]
    for rate in sorted(by):
        for route in READ_ROUTES:
            xs = [r.get("routes", {}).get(route, {}) for r in by[rate]]
            lines.append(f"| {rate} | {route} | {cell([x.get('p50') for x in xs])} | {cell([x.get('p95') for x in xs])} | "
                         f"{cell([x.get('p99') for x in xs])} | {cell([x.get('n') for x in xs], digits=0)} | "
                         f"{cell([x.get('error_rate') for x in xs], 100, 2)} |")
    return "\n".join(lines)


def e2(runs, out_dir):
    by = defaultdict(list)
    for run, res in runs:
        by[run["args"]["workers"]].append(res)
    lines = ["| workers | target/s | measured/s | verdicts/s | p50 s | p95 s | p99 s | n | saturated runs |",
             "|---|---|---|---|---|---|---|---|---|"]
    curves, capacity, unsaturated = {}, {}, {}
    for w in sorted(by):
        rows, calm = [], []
        for rate in sorted({s["rate"] for r in by[w] for s in r["steps"]}):
            steps = [s for r in by[w] for s in r["steps"] if s["rate"] == rate]
            thr, p95 = stats.summarize([s["throughput"] for s in steps]), stats.summarize([s["p95"] for s in steps])
            measured = stats.summarize([s.get("measured_rate") for s in steps])
            hot = sum(1 for s in steps if s["saturated"])
            lines.append(f"| {w} | {rate:g} | {cell([s.get('measured_rate') for s in steps], digits=2)} | "
                         f"{cell([s['throughput'] for s in steps], digits=2)} | {qcell(steps, 'p50')} | {qcell(steps, 'p95')} | "
                         f"{qcell(steps, 'p99')} | {cell([s.get('n') for s in steps], digits=0)} | {hot}/{len(steps)} |")
            cut = any(s.get("p95_censored") for s in steps)
            rows.append({"rate": measured["median"] if measured else rate, "throughput": thr and thr["median"],
                         "p95": (steps[0].get("histogram_top_s") or 30.0) if cut else (p95 and p95["median"]),
                         "p95_censored": cut})
            if 2 * hot < len(steps):
                calm.append(rate)
        curves[w] = rows
        cap = stats.summarize([max((s["throughput"] or 0) for s in r["steps"]) for r in by[w]])
        capacity[w] = cap["median"] if cap else None
        unsaturated[w] = max(calm) if calm else None   # spec §3.3: the highest step whose queue does not grow
    charts.capacity_png(Path(out_dir) / "capacity.png", curves)
    (Path(out_dir) / "e2-capacity.json").write_text(json.dumps({str(k): v for k, v in capacity.items()}, indent=1))
    lines += ["", "| workers | capacity, verdicts/s (median of the runs' best step) | highest unsaturated step, /s | SYSTEM_ERROR per run |",
              "|---|---|---|---|"]
    lines += [f"| {w} | {'—' if c is None else f'{c:.2f}'} | {'—' if unsaturated[w] is None else f'{unsaturated[w]:g}'} | "
              f"{cell([r.get('system_errors') for r in by[w]], digits=0)} |" for w, c in sorted(capacity.items())]
    lines += ["", "![capacity](capacity.png)"]
    return "\n".join(lines)


def e3(runs):
    rs = [res for _, res in runs]
    lines = ["| route | p50 ms | p95 ms | p99 ms | n | errors % |", "|---|---|---|---|---|---|"]
    for route in READ_ROUTES + ["submit"]:
        xs = [r.get("routes", {}).get(route, {}) for r in rs]
        lines.append(f"| {route} | {cell([x.get('p50') for x in xs])} | {cell([x.get('p95') for x in xs])} | "
                     f"{cell([x.get('p99') for x in xs])} | {cell([x.get('n') for x in xs], digits=0)} | "
                     f"{cell([x.get('error_rate') for x in xs], 100, 2)} |")
    lines += ["", "| measure | value |", "|---|---|",
              f"| judge latency p95, s (n) | {qcell(rs, 'judge_p95')} ({cell([r.get('judge_n') for r in rs], digits=0)}) |",
              f"| SYSTEM_ERROR submissions | {cell([r.get('system_errors') for r in rs], digits=0)} |",
              f"| verdict consumer lag, max | {cell([r.get('verdict_lag_max') for r in rs], digits=0)} |",
              f"| outbox oldest age, max, s | {cell([r.get('outbox_age_max') for r in rs])} |"]
    for job in sorted({j for r in rs for j in (r.get("heap_max_bytes") or {})}):
        lines.append(f"| heap max, {job}, MB | {cell([(r.get('heap_max_bytes') or {}).get(job) for r in rs], 1 / 2**20, 0)} |")
    return "\n".join(lines)


def e4(runs):
    by = defaultdict(list)
    for run, res in runs:
        by[res.get("fault") or run["args"]["fault"]].append(res)
    lines = ["| fault | route | errors during % | first error after inject, s | first success after removal, s | "
             "queue back, s | breaker open after, s | alerts firing, s after inject | invariant | SYSTEM_ERROR |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for f in sorted(by):
        rs = by[f]
        ok = sum(1 for r in rs if r.get("invariant_ok"))
        names = sorted({a for r in rs for a in (r.get("alerts_after_s") or {})})
        alerts = "; ".join(f"{a.split('=', 1)[-1]} {cell([(r.get('alerts_after_s') or {}).get(a) for r in rs], digits=0)}" for a in names) or "none"
        for k, route in enumerate(sorted({x for r in rs for x in r.get("routes", {})})):
            xs = [r.get("routes", {}).get(route, {}) for r in rs]
            common = (f"{cell([r.get('queue_recovery_s') for r in rs], digits=0)} | "
                      f"{cell([r.get('breaker_open_after_s') for r in rs], digits=0)} | {alerts} | {ok}/{len(rs)} | "
                      f"{cell([r.get('system_errors') for r in rs])}") if k == 0 else " | | | | "
            lines.append(f"| {f if k == 0 else ''} | {route} | {cell([x.get('error_rate_during') for x in xs], 100)} | "
                         f"{cell([x.get('first_error_after_inject_ms') for x in xs], 1 / 1000)} | "
                         f"{cell([x.get('first_success_after_remove_ms') for x in xs], 1 / 1000)} | {common} |")
    return "\n".join(lines)


def write(results_dir, exp):
    results_dir = Path(results_dir)
    runs = load(results_dir, exp)
    body = {"e1": lambda: e1(runs), "e2": lambda: e2(runs, results_dir), "e3": lambda: e3(runs), "e4": lambda: e4(runs)}[exp]()
    path = results_dir / f"summary-{exp}.md"
    dropped = sum(1 for _, res in runs if (res.get("dropped_iterations") or 0) > 0)
    path.write_text(f"# {TITLES[exp]}\n\nRuns: {len(runs)}. Each cell: median (min–max) over the runs. "
                    f"Runs with dropped iterations: {dropped} of {len(runs)} (k6 could not start an arrival on time).\n\n{body}\n")
    return str(path)


def lag_threshold(results_dir):
    lags = [s["verdict_lag_max"] for _, res in load(results_dir, "e2") for s in res["steps"] if not s["saturated"]]
    lags += [res.get("verdict_lag_max") for _, res in load(results_dir, "e3")]
    return stats.lag_threshold(lags)
