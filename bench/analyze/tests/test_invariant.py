import json

from oj_analyze import invariant as inv


def line(msg, source="console"):
    return json.dumps({"level": "info", "msg": json.dumps(msg) if isinstance(msg, dict) else msg, "source": source, "time": "t"})


def test_parse_keeps_only_our_console_events():
    lines = [line({"ev": "accepted", "id": "a", "t": 1}), line("plain text"), line({"ev": "x"}, source="http"), "not json", ""]
    assert inv.parse_k6_log(lines) == [{"ev": "accepted", "id": "a", "t": 1}]


def test_accepted_ids_come_from_accepted_events_only():
    events = [{"ev": "accepted", "id": "a"}, {"ev": "rejected", "status": 429}, {"ev": "req", "route": "submit", "status": 200}]
    assert inv.accepted_ids(events) == ["a"]


def test_every_accepted_submission_found_and_terminal_is_ok():
    found = [{"id": "a", "status": 0}, {"id": "b", "status": -1}, {"id": "z", "status": 6}]  # z: another run's
    assert inv.check(["a", "b"], found) == {"accepted": 2, "missing": [], "nonterminal": [], "system_error": [],
                                           "by_status": {"-1": 1, "0": 1}, "ok": True}


def test_a_missing_or_pending_submission_fails_the_run():
    r = inv.check(["a", "b", "c"], [{"id": "a", "status": 0}, {"id": "b", "status": 7}])
    assert r["missing"] == ["c"] and r["nonterminal"] == ["b"] and r["ok"] is False


def test_a_duplicate_accepted_line_counts_once():
    assert inv.check(["a", "a"], [{"id": "a", "status": 0}])["accepted"] == 1


def test_a_system_error_is_terminal_but_listed():
    # The reconcile job flips a submission queued > 5 min to SYSTEM_ERROR (5): terminal, so the run stays ok (spec),
    # but the report must show it (review C1/I3).
    r = inv.check(["a", "b"], [{"id": "a", "status": 5}, {"id": "b", "status": 0}])
    assert r["ok"] is True and r["system_error"] == ["a"] and r["by_status"] == {"0": 1, "5": 1}
