"""Before/after tables and the targets of sub-projects 6 and 7 (sub-project 6 spec §3.3, §6; sub-project 7 spec §6):
the same analysis over the earlier runs and the re-measured ones. python -m oj_analyze compare <e3|e4>
--before <run dirs> --after <run dirs> → Markdown."""
import csv
import json
from collections import defaultdict
from pathlib import Path
from statistics import median

from . import timeline
from . import invariant as inv
from .summarize import READ_ROUTES, cell

# The routes a stopped service fails and their p95 target during the fault, ms (spec §3.2 A). Submit during c1 waits
# out the gRPC retries — three attempts, 50 ms apart since sub-project 7 (200 ms before) — until the breaker opens.
STOPPED_SERVICE_P95 = {"c1": {"problem_list": 100, "problem_detail": 100, "submit": 500},
                       "c5": {"history": 100, "submit": 100}}
REDIS_READ_OVERHEAD = 20   # ms, c6, read routes
REDIS_SUBMIT_P95 = 100     # ms, c6
RECOVERY_S = 5             # s, c6, every route
DETECTION_S = 60           # s after the injection, every fault
E3_SLACK = 1.1             # the new median at most this × the before runs' highest
QUEUE_BACK_S = 70          # s, c4, every run (sub-project 7 §6)


def alerts_fired(run_dir):
    p = Path(run_dir) / "series" / "alerts.csv"
    if not p.exists():
        return set()
    with open(p, newline="") as f:
        return {row["series"].split("=", 1)[-1] for row in csv.DictReader(f) if row["value"] and float(row["value"]) >= 1}


def load(dirs):
    """(run.json, results.json) per directory; E4 runs get fault_latency from their k6.log, every run alerts_fired."""
    runs = []
    for d in map(Path, dirs):
        run = json.loads((d / "run.json").read_text())
        res = json.loads((d / "results.json").read_text())
        log = d / "k6.log"
        events = inv.parse_k6_log(log.read_text().splitlines()) if log.exists() else []
        fault = run.get("fault") or {}
        if {"inject_ms", "remove_ms"} <= set(fault):
            res["fault_latency"] = timeline.fault_latency(events, fault["inject_ms"], fault["remove_ms"])
        res["alerts_fired"] = sorted(alerts_fired(d))
        runs.append((run, res))
    return runs


def first_alert(res):
    xs = [v for v in (res.get("alerts_after_s") or {}).values() if v is not None]
    return min(xs) if xs else None


def failed_dispatches(res):
    d = res.get("dispatch_failed_during")
    return None if d is None else sum(d.values())


def latency(route, *path):
    def get(res):
        v = (res.get("fault_latency") or {}).get(route, {})
        for k in path:
            v = v.get(k) if isinstance(v, dict) else None
        return v
    return get


def pair(before, after, get, scale=1.0, digits=1):
    return f"{cell([get(r) for r in before], scale, digits)} → {cell([get(r) for r in after], scale, digits)}"


def _median(xs):
    xs = [x for x in xs if x is not None]
    return median(xs) if xs else None


def _fmt(x):
    return "—" if x is None else f"{x:.0f}"


def _verdict(ok):
    return "PASS" if ok else "MISS"


def by_fault(runs):
    out = defaultdict(list)
    for run, res in runs:
        out[res.get("fault") or run["args"]["fault"]].append(res)
    return dict(out)


def e4(before, after):
    b, a = by_fault(before), by_fault(after)
    faults = sorted(set(b) | set(a))
    lines = ["| fault | route | errors during % | p95 during, ms | p95 overhead, ms | latency recovery, s |",
             "|---|---|---|---|---|---|"]
    for f in faults:
        bf, af = b.get(f, []), a.get(f, [])
        routes = sorted({r for res in bf + af for r in (res.get("fault_latency") or {})})
        for k, route in enumerate(routes):
            errors = lambda res, route=route: (res.get("routes") or {}).get(route, {}).get("error_rate_during")
            lines.append(f"| {f if k == 0 else ''} | {route} | {pair(bf, af, errors, 100)} | "
                         f"{pair(bf, af, latency(route, 'during', 'p95'), digits=0)} | "
                         f"{pair(bf, af, latency(route, 'overhead_p95'), digits=0)} | "
                         f"{pair(bf, af, latency(route, 'recovery_s'), digits=0)} |")
    lines += ["", "| fault | first alert, s after inject | queue back, s | failed dispatches during the fault |",
              "|---|---|---|---|"]
    for f in faults:
        bf, af = b.get(f, []), a.get(f, [])
        lines.append(f"| {f} | {pair(bf, af, first_alert, digits=0)} | "
                     f"{pair(bf, af, lambda r: r.get('queue_recovery_s'), digits=0)} | "
                     f"{pair(bf, af, failed_dispatches, digits=0)} |")
    lines += ["", "Targets (spec §6), over the re-measured runs:", ""] + [f"- {t}" for t in e4_targets(a)]
    return "\n".join(lines)


def e4_targets(a):
    out = []
    every = [r for rs in a.values() for r in rs]
    held = sum(1 for r in every if r.get("invariant_ok"))
    errors = sum(r.get("system_errors") or 0 for r in every)
    out.append(f"{_verdict(held == len(every) and errors == 0)} invariant held in {held}/{len(every)} runs, "
               f"{errors} SYSTEM_ERROR")
    for f in sorted(a):
        firsts = [first_alert(r) for r in a[f]]
        ok = all(x is not None and x <= DETECTION_S for x in firsts)
        out.append(f"{_verdict(ok)} {f}: first alert ≤ {DETECTION_S} s after inject in every run "
                   f"({', '.join('none' if x is None else _fmt(x) for x in firsts)})")
    for f, limits in STOPPED_SERVICE_P95.items():
        for route, limit in limits.items():
            if f in a:
                m = _median([latency(route, "during", "p95")(r) for r in a[f]])
                out.append(f"{_verdict(m is not None and m < limit)} {f} {route}: p95 during < {limit} ms (median {_fmt(m)})")
    if "c6" in a:
        c6 = a["c6"]
        routes = sorted({r for res in c6 for r in (res.get("fault_latency") or {})})
        for route in [r for r in routes if r != "submit"]:
            m = _median([latency(route, "overhead_p95")(r) for r in c6])
            out.append(f"{_verdict(m is not None and m < REDIS_READ_OVERHEAD)} c6 {route}: overhead < "
                       f"{REDIS_READ_OVERHEAD} ms (median {_fmt(m)})")
        m = _median([latency("submit", "during", "p95")(r) for r in c6])
        out.append(f"{_verdict(m is not None and m < REDIS_SUBMIT_P95)} c6 submit: p95 during < {REDIS_SUBMIT_P95} ms "
                   f"(median {_fmt(m)})")
        for route in routes:
            xs = [latency(route, "recovery_s")(r) for r in c6]
            ok = all(x is not None and x < RECOVERY_S for x in xs)
            out.append(f"{_verdict(ok)} c6 {route}: latency recovery < {RECOVERY_S} s in every run "
                       f"({', '.join(_fmt(x) for x in xs)})")
    if "c3" in a:
        fails = [failed_dispatches(r) for r in a["c3"]]
        ok = all(x is not None and x <= 1 for x in fails)
        out.append(f"{_verdict(ok)} c3: at most the one failed dispatch that marks the sandbox down, per run "
                   f"({', '.join(_fmt(x) for x in fails)})")
    if "c4" in a:
        c4 = a["c4"]
        down = sum(1 for r in c4 if "JudgeWorkerDown" in (r.get("alerts_fired") or []))
        out.append(f"{_verdict(down == 0)} c4: JudgeWorkerDown in no run ({down} of {len(c4)})")
        qs = [r.get("queue_recovery_s") for r in c4]
        ok = all(q is not None and q <= QUEUE_BACK_S for q in qs)
        out.append(f"{_verdict(ok)} c4: queue back ≤ {QUEUE_BACK_S} s in every run ({', '.join(_fmt(q) for q in qs)})")
    return out


def within_range(before, after, slack=E3_SLACK):
    b = [x for x in before if x is not None]
    a = [x for x in after if x is not None]
    return bool(a) and bool(b) and median(a) <= slack * max(b)


def e3(before, after):
    b, a = [res for _, res in before], [res for _, res in after]
    lines = ["| route | p50, ms | p95, ms | within range |", "|---|---|---|---|"]
    targets = []
    for route in READ_ROUTES + ["submit"]:
        get = {q: (lambda res, q=q, route=route: (res.get("routes") or {}).get(route, {}).get(q)) for q in ("p50", "p95")}
        ok = all(within_range([g(r) for r in b], [g(r) for r in a]) for g in get.values())
        lines.append(f"| {route} | {pair(b, a, get['p50'])} | {pair(b, a, get['p95'])} | {'yes' if ok else 'no'} |")
        targets.append(f"{_verdict(ok)} {route}: median p50 and p95 ≤ {E3_SLACK} × the before runs' highest")
    fired = sorted({x for r in a for x in r["alerts_fired"]})
    targets.insert(0, f"{_verdict(not fired)} no alert fired in any run ({', '.join(fired) or 'none'})")
    return "\n".join(lines + ["", "Targets (spec §6), over the re-measured runs:", ""] + [f"- {t}" for t in targets])


def write(exp, before_dirs, after_dirs):
    before, after = load(before_dirs), load(after_dirs)
    return e3(before, after) if exp == "e3" else e4(before, after)
