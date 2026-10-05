"""The no-lost-submission invariant (spec §3.5, §5): every accepted submit ends in a terminal verdict."""
import json

NON_TERMINAL = {6, 7}  # PENDING, JUDGING
SYSTEM_ERROR = 5


def parse_k6_log(lines):
    """k6 --log-format=json lines → the event objects our scripts console.log()ged; everything else is skipped."""
    out = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(rec, dict) or rec.get("source") != "console":
            continue
        try:
            msg = json.loads(rec.get("msg", ""))
        except (json.JSONDecodeError, TypeError):
            continue
        if isinstance(msg, dict) and "ev" in msg:
            out.append(msg)
    return out


def accepted_ids(events):
    return [e["id"] for e in events if e.get("ev") == "accepted"]


def check(accepted, found):
    """found: [{"id", "status"}] from check.js (all of the users' submissions, other runs' included). SYSTEM_ERROR is
    terminal, so it keeps the run ok (spec), but it is listed: the reconcile job flips a submission queued > 5 min to
    it and throws its verdict away (review C1/I3)."""
    status = {f["id"]: f["status"] for f in found}
    ids = set(accepted)
    missing = sorted(i for i in ids if i not in status)
    nonterminal = sorted(i for i in ids if i in status and status[i] in NON_TERMINAL)
    system_error = sorted(i for i in ids if status.get(i) == SYSTEM_ERROR)
    by_status = {}
    for i in ids:
        if i in status:
            by_status[str(status[i])] = by_status.get(str(status[i]), 0) + 1
    return {"accepted": len(ids), "missing": missing, "nonterminal": nonterminal, "system_error": system_error,
            "by_status": dict(sorted(by_status.items())), "ok": not missing and not nonterminal}
