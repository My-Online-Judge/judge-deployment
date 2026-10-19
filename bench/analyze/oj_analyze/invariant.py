"""The no-lost-submission invariant (spec §3.5, §5): every accepted submit ends in a terminal verdict."""
import json

NON_TERMINAL = {6, 7}  # PENDING, JUDGING
SYSTEM_ERROR = 5
# The reconcile job's messages (SP11); the pre-SP11 "Judging timed out: no verdict within 5 minutes" matches by prefix.
TIMEOUT_MESSAGES = ("Judging timed out", "Judging request lost")


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
    terminal, so it keeps the run ok (spec), but it is listed: the reconcile job flips a submission judging > 3 min or
    pending > 30 min to it and throws its verdict away (review C1/I3). timeout_system_error: those it flipped."""
    status = {f["id"]: f["status"] for f in found}
    ids = set(accepted)
    missing = sorted(i for i in ids if i not in status)
    nonterminal = sorted(i for i in ids if i in status and status[i] in NON_TERMINAL)
    system_error = sorted(i for i in ids if status.get(i) == SYSTEM_ERROR)
    timeout = sorted(i for i in system_error
                     if (next(f for f in found if f["id"] == i).get("errorMessage") or "").startswith(TIMEOUT_MESSAGES))
    by_status = {}
    for i in ids:
        if i in status:
            by_status[str(status[i])] = by_status.get(str(status[i]), 0) + 1
    return {"accepted": len(ids), "missing": missing, "nonterminal": nonterminal, "system_error": system_error,
            "timeout_system_error": timeout,
            "by_status": dict(sorted(by_status.items())), "ok": not missing and not nonterminal}


def rejections(events):
    """The submits the API refused: "<status> <message>" → count (503 'The judge is busy…' is admission control)."""
    out = {}
    for e in events:
        if e.get("ev") == "rejected":
            key = f"{e.get('status')} {e.get('message')}" if e.get("message") is not None else f"{e.get('status')} null"
            out[key] = out.get(key, 0) + 1
    return out
