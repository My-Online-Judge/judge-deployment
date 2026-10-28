"""
Minimal mock of the QingdaoU judge_server, faithful to the wire protocol the backend
depends on (token = sha256(TOKEN), /judge envelope, per-testcase result array, heartbeat).
NOT a real sandbox — verdicts are driven by markers in the submitted source so each backend
mapping branch (AC/WA/TLE/MLE/RE/CE/SE) can be exercised deterministically.
"""
import hashlib
import json
import os
import threading
import time
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ.get("TOKEN", "123456")
EXPECTED_TOKEN = hashlib.sha256(TOKEN.encode()).hexdigest()
SERVICE_URL = os.environ.get("SERVICE_URL", "http://judge-server:8080")
BACKEND_URL = os.environ.get("BACKEND_URL", "")
# The worker's synced bundles (the real sandbox reads the same directory): <id>/info holds test_case_number.
TEST_CASE_DIR = os.environ.get("TEST_CASE_DIR", "/test_case")
# A source with TRIGGER_SLOW takes this long to judge, so a backlog can build behind it (the autoscaler is tried with it).
SLOW_SECONDS = float(os.environ.get("MOCK_SLOW_SECONDS", "3"))


def make_case(result, error=0, tc="1"):
    return {
        "cpu_time": 12, "real_time": 15, "memory": 3624960,
        "signal": 0, "exit_code": 0, "error": error, "result": result,
        "test_case": tc, "output_md5": "deadbeef", "output": "mock",
    }


# marker in the source -> the result code of the case it replaces (the second case, or the only one)
TRIGGERS = (("TRIGGER_SE", 5), ("TRIGGER_WA", -1), ("TRIGGER_TLE", 1), ("TRIGGER_MLE", 3), ("TRIGGER_RE", 4))


def bundle_cases(test_case_id):
    """The case names of the synced bundle, in qduoj's order, or None when it cannot be read (no cache mounted, no such
    bundle, a corrupt info). The real server judges every case of the bundle and answers one result per case, so the
    worker checks the count against test_case_number: the mock has to answer with as many."""
    if not test_case_id:
        return None
    root = os.path.realpath(TEST_CASE_DIR)
    info_path = os.path.realpath(os.path.join(root, test_case_id, "info"))
    if os.path.commonpath([root, info_path]) != root:        # a bundle id is a name, never a path out of the cache
        return None
    try:
        with open(info_path, encoding="utf-8") as f:
            names = list(json.load(f)["test_cases"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
    return [str(n) for n in names] or None


def triggered_results(src, names):
    """One accepted result per case; a TRIGGER_* marker replaces the second case's (the first when there is only one),
    so the verdict aggregation (first failing case wins) is exercised with the bundle's real number of cases."""
    results = [make_case(0, tc=n) for n in names]
    for marker, code in TRIGGERS:
        if marker in src:
            i = 1 if len(names) > 1 else 0
            results[i] = make_case(code, error=-10 if code == 5 else 0, tc=names[i])
            break
    return results


def judge_payload(src, test_case=None, test_case_id=None):
    # err-envelope branches
    if "TRIGGER_CE" in src:
        return {"err": "CompileError", "data": "mock: error: expected ';' before '}'"}
    # A run (inline test_case, Run code design §13): one result per case, echoing the case's input as the program's
    # output (unless a TRIGGER_* marker shapes the verdict), so the portal's panel shows something per case.
    if isinstance(test_case, list):
        names = [str(i + 1) for i in range(len(test_case))]
        if not any(m in src for m, _ in TRIGGERS):
            return {"err": None, "data": [
                {**make_case(0, tc=n), "output": (c.get("input", "") if isinstance(c, dict) else "")}
                for n, c in zip(names, test_case)]}
        return {"err": None, "data": triggered_results(src, names)}
    # A submission: as many results as the bundle has cases. A bundle the mock cannot read keeps the old fixed answer.
    names = bundle_cases(test_case_id)
    if names is not None:
        return {"err": None, "data": triggered_results(src, names)}
    if "TRIGGER_SE" in src:
        return {"err": None, "data": [make_case(0), make_case(5, error=-10, tc="2")]}
    if "TRIGGER_WA" in src:
        return {"err": None, "data": [make_case(0), make_case(-1, tc="2"), make_case(0, tc="3")]}
    if "TRIGGER_TLE" in src:
        return {"err": None, "data": [make_case(0), make_case(1, tc="2")]}
    if "TRIGGER_MLE" in src:
        return {"err": None, "data": [make_case(0), make_case(3, tc="2")]}
    if "TRIGGER_RE" in src:
        return {"err": None, "data": [make_case(0), make_case(4, tc="2")]}
    return {"err": None, "data": [make_case(0, tc="1"), make_case(0, tc="2"), make_case(0, tc="3")]}


def pause_for(src):
    """The judgement's duration: instant, or SLOW_SECONDS for a TRIGGER_SLOW source."""
    if "TRIGGER_SLOW" in src:
        time.sleep(SLOW_SECONDS)


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        # Spring RestClient sends Transfer-Encoding: chunked (even alongside Content-Length).
        # Per HTTP, chunked takes precedence, so decode chunks when present.
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            data = b""
            while True:
                line = self.rfile.readline().strip()
                if not line:
                    continue
                size = int(line, 16)
                if size == 0:
                    self.rfile.readline()  # consume trailing CRLF
                    break
                data += self.rfile.read(size)
                self.rfile.readline()  # consume CRLF after each chunk
            return data
        length = int(self.headers.get("Content-Length", 0))
        return self.rfile.read(length) if length else b"{}"

    def do_POST(self):
        token = self.headers.get("X-Judge-Server-Token")
        if token != EXPECTED_TOKEN:
            return self._send(200, {"err": "TokenVerificationFailed", "data": "invalid token"})
        raw = self._read_body()
        try:
            data = json.loads(raw)
        except Exception:
            data = {}
        if self.path.rstrip("/").endswith("/judge") or self.path == "/judge":
            src = data.get("src", "")
            print(f"[judge] keys={list(data.keys())} src={src[:80]!r}", flush=True)
            pause_for(src)
            return self._send(200, judge_payload(src, data.get("test_case"), data.get("test_case_id")))
        if self.path.rstrip("/").endswith("/ping"):
            # What the real server's /ping answers (its server_info); judge-worker relays it as the sandbox's heartbeat.
            return self._send(200, {"err": None, "data": {
                "hostname": os.environ.get("HOSTNAME", "mock-judge-server"), "judger_version": "2.1.1-mock",
                "cpu_core": 4, "memory": 12.5, "cpu": 3.0}})
        return self._send(200, {"err": None, "data": "ok"})

    def do_GET(self):
        self._send(200, {"err": None, "data": {"hostname": "mock", "judger_version": "2.1.1"}})

    def log_message(self, *args):
        pass  # quiet


def send_heartbeats():
    if not BACKEND_URL:
        return
    payload = json.dumps({
        "hostname": "mock-judge-server", "judger_version": "2.1.1-mock",
        "cpu_core": 4, "memory": 12.5, "cpu": 3.0,
        "service_url": SERVICE_URL, "action": "heartbeat",
    }).encode()
    while True:
        try:
            req = urllib.request.Request(BACKEND_URL, data=payload, method="POST")
            req.add_header("Content-Type", "application/json")
            req.add_header("X-Judge-Server-Token", EXPECTED_TOKEN)
            with urllib.request.urlopen(req, timeout=5) as r:
                print(f"[heartbeat] {r.status}", flush=True)
        except Exception as e:
            print(f"[heartbeat] failed: {e}", flush=True)
        time.sleep(10)


if __name__ == "__main__":
    threading.Thread(target=send_heartbeats, daemon=True).start()
    print(f"mock judge_server on :8080 (expected token {EXPECTED_TOKEN[:12]}...)", flush=True)
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
