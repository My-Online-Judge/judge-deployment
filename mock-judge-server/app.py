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


def make_case(result, error=0, tc="1"):
    return {
        "cpu_time": 12, "real_time": 15, "memory": 3624960,
        "signal": 0, "exit_code": 0, "error": error, "result": result,
        "test_case": tc, "output_md5": "deadbeef", "output": "mock",
    }


def judge_payload(src):
    # err-envelope branches
    if "TRIGGER_CE" in src:
        return {"err": "CompileError", "data": "mock: error: expected ';' before '}'"}
    # per-testcase array branches: first AC, then the triggered verdict (tests ACM aggregation)
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
    # default: all accepted
    return {"err": None, "data": [make_case(0, tc="1"), make_case(0, tc="2"), make_case(0, tc="3")]}


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
            return self._send(200, judge_payload(src))
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
