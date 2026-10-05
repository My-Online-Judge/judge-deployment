"""python -m oj_analyze export|invariant|steps|summarize|lag-threshold — used by bench/run.sh and bench/campaign.sh."""
import argparse
import json
import sys
from pathlib import Path

from . import export, stats, summarize
from . import invariant as inv
from .prom import Prom


def cmd_invariant(run_dir):
    events = inv.parse_k6_log((run_dir / "k6.log").read_text().splitlines())
    found = json.loads((run_dir / "found.json").read_text())["found"]
    result = inv.check(inv.accepted_ids(events), found)
    (run_dir / "invariant.json").write_text(json.dumps(result, indent=1))
    print(f"invariant {'ok' if result['ok'] else 'FAIL'}: {result['accepted']} accepted, "
          f"{len(result['missing'])} missing, {len(result['nonterminal'])} not terminal, "
          f"{len(result['system_error'])} SYSTEM_ERROR")
    return 0


def cmd_steps(run_dir):
    res = json.loads((run_dir / "results.json").read_text())
    capacity = max((s["throughput"] or 0) for s in res["steps"])
    print(",".join(f"{r:g}" for r in stats.pilot_steps(capacity)))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="oj_analyze")
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export")
    e.add_argument("run_dir", type=Path)
    e.add_argument("--prom", default="http://prometheus:9090")
    for name in ("invariant", "steps"):
        sub.add_parser(name).add_argument("run_dir", type=Path)
    s = sub.add_parser("summarize")
    s.add_argument("results_dir", type=Path)
    s.add_argument("exp", choices=["e1", "e2", "e3", "e4"])
    sub.add_parser("lag-threshold").add_argument("results_dir", type=Path)
    a = p.parse_args(argv)
    if a.cmd == "export":
        export.export_run(a.run_dir, Prom(a.prom))
        print(f"exported {a.run_dir}")
        return 0
    if a.cmd == "invariant":
        return cmd_invariant(a.run_dir)
    if a.cmd == "steps":
        return cmd_steps(a.run_dir)
    if a.cmd == "summarize":
        print(summarize.write(a.results_dir, a.exp))
        return 0
    print(summarize.lag_threshold(a.results_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
