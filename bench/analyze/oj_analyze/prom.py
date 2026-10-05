"""A small Prometheus HTTP API client. `fetch(path, params) → decoded JSON` is injectable for the tests."""
import json
import urllib.parse
import urllib.request


def _num(v):
    x = float(v)
    return None if x != x or x in (float("inf"), float("-inf")) else x


def _key(metric):
    return ",".join(f"{k}={v}" for k, v in sorted(metric.items())) or "value"


class Prom:
    def __init__(self, base_url, fetch=None):
        self.base = base_url.rstrip("/")
        self.fetch = fetch or self._http

    def _http(self, path, params):
        with urllib.request.urlopen(f"{self.base}{path}?{urllib.parse.urlencode(params)}", timeout=60) as r:
            return json.load(r)

    def query(self, q, at):
        """The value of the first series at epoch seconds `at`; None when there is no data."""
        res = self.fetch("/api/v1/query", {"query": q, "time": at})["data"]["result"]
        return _num(res[0]["value"][1]) if res else None

    def vector(self, q, at):
        res = self.fetch("/api/v1/query", {"query": q, "time": at})["data"]["result"]
        return {_key(s["metric"]): _num(s["value"][1]) for s in res}

    def label_values(self, label, match):
        return self.fetch(f"/api/v1/label/{label}/values", {"match[]": match})["data"]

    def range(self, q, start, end, step=5):
        res = self.fetch("/api/v1/query_range", {"query": q, "start": start, "end": end, "step": step})["data"]["result"]
        return {_key(s["metric"]): [(float(t), _num(v)) for t, v in s["values"]] for s in res}
