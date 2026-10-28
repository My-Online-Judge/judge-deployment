"""The mock must answer like the real judge-server where the worker can tell: one result per test case of the bundle
(qduoj's JudgeClient.run() judges every case and returns every result, whatever the verdicts), a dict for /ping, and the
token check. Run: python3 -m unittest discover -s mock-judge-server -p 'test_*.py'"""
import json
import os
import tempfile
import threading
import unittest
import urllib.request
from http.server import ThreadingHTTPServer

import app


def write_bundle(root, bundle_id, names):
    d = os.path.join(root, bundle_id)
    os.makedirs(d)
    info = {"test_case_number": len(names), "spj": False,
            "test_cases": {n: {"input_name": f"{n}.in", "output_name": f"{n}.out"} for n in names}}
    with open(os.path.join(d, "info"), "w") as f:
        json.dump(info, f)
    return bundle_id


class JudgePayloadTest(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self._old = app.TEST_CASE_DIR
        app.TEST_CASE_DIR = self.root

    def tearDown(self):
        app.TEST_CASE_DIR = self._old

    def results(self, src, bundle):
        payload = app.judge_payload(src, None, bundle)
        self.assertIsNone(payload["err"])
        return payload["data"]

    def test_one_accepted_result_per_case_of_the_bundle(self):
        for names in (["1"], ["1", "2"], ["1", "2", "3", "4", "5"]):
            with self.subTest(cases=len(names)):
                bundle = write_bundle(self.root, f"p{len(names)}__h", names)
                data = self.results("print(1)", bundle)
                self.assertEqual([r["test_case"] for r in data], names)
                self.assertEqual({r["result"] for r in data}, {0})

    def test_a_trigger_replaces_the_second_result_and_keeps_the_count(self):
        bundle = write_bundle(self.root, "five__h", ["1", "2", "3", "4", "5"])
        for marker, code in (("TRIGGER_WA", -1), ("TRIGGER_TLE", 1), ("TRIGGER_MLE", 3), ("TRIGGER_RE", 4)):
            with self.subTest(marker=marker):
                data = self.results(f"x # {marker}", bundle)
                self.assertEqual([r["result"] for r in data], [0, code, 0, 0, 0])

    def test_a_trigger_on_a_single_case_bundle_replaces_that_case(self):
        bundle = write_bundle(self.root, "one__h", ["1"])
        self.assertEqual([r["result"] for r in self.results("x # TRIGGER_RE", bundle)], [4])

    def test_a_sandbox_error_is_a_system_error_result_with_an_error_code(self):
        bundle = write_bundle(self.root, "three__h", ["1", "2", "3"])
        data = self.results("x # TRIGGER_SE", bundle)
        self.assertEqual([(r["result"], r["error"]) for r in data], [(0, 0), (5, -10), (0, 0)])

    def test_a_compile_error_is_an_envelope_error_whatever_the_bundle(self):
        bundle = write_bundle(self.root, "any__h", ["1", "2"])
        payload = app.judge_payload("x # TRIGGER_CE", None, bundle)
        self.assertEqual(payload["err"], "CompileError")

    def test_a_run_answers_one_result_per_inline_case_and_a_trigger_keeps_that_count(self):
        cases = [{"input": "a\n"}, {"input": "b\n"}, {"input": "c\n"}, {"input": "d\n"}]
        plain = app.judge_payload("print(1)", cases)["data"]
        self.assertEqual([r["output"] for r in plain], ["a\n", "b\n", "c\n", "d\n"])
        triggered = app.judge_payload("x # TRIGGER_WA", cases)["data"]
        self.assertEqual([r["result"] for r in triggered], [0, -1, 0, 0])

    def test_a_bundle_the_mock_cannot_read_keeps_the_old_fixed_answer(self):
        # Nothing to count (no cache mounted, or a corrupt info): the mock's historical 3 results.
        self.assertEqual(len(self.results("print(1)", "missing__h")), 3)
        os.makedirs(os.path.join(self.root, "broken__h"))
        with open(os.path.join(self.root, "broken__h", "info"), "w") as f:
            f.write("not json")
        self.assertEqual(len(self.results("print(1)", "broken__h")), 3)

    def test_a_bundle_id_cannot_climb_out_of_the_cache_directory(self):
        outside = tempfile.mkdtemp()
        write_bundle(outside, "evil", ["1", "2", "3", "4", "5", "6", "7"])
        rel = os.path.relpath(os.path.join(outside, "evil"), self.root)
        self.assertEqual(len(self.results("print(1)", rel)), 3)


class HttpTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), app.Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_address[1]}"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()

    def post(self, path, body=None, token=None):
        req = urllib.request.Request(self.base + path, data=json.dumps(body or {}).encode(), method="POST")
        req.add_header("Content-Type", "application/json")
        req.add_header("X-Judge-Server-Token", token or app.EXPECTED_TOKEN)
        with urllib.request.urlopen(req, timeout=5) as r:
            return json.loads(r.read())

    def test_ping_answers_the_server_info_dict_the_workers_relay_needs(self):
        reply = self.post("/ping")
        self.assertIsNone(reply["err"])
        info = dict(reply["data"])            # the worker does dict(pong.json()["data"])
        for key in ("hostname", "judger_version", "cpu_core", "memory", "cpu"):
            self.assertIn(key, info)

    def test_a_wrong_token_is_refused_with_the_envelope_error(self):
        self.assertEqual(self.post("/ping", token="nope")["err"], "TokenVerificationFailed")


if __name__ == "__main__":
    unittest.main()
