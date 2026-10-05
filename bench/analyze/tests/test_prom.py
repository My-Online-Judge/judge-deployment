from oj_analyze.prom import Prom


def fake(responses):
    calls = []

    def fetch(path, params):
        calls.append((path, params))
        return responses[(path, params["query"])]

    return fetch, calls


def test_instant_query_returns_the_first_value_or_none():
    fetch, calls = fake({
        ("/api/v1/query", "a"): {"data": {"result": [{"metric": {}, "value": [1, "2.5"]}]}},
        ("/api/v1/query", "b"): {"data": {"result": []}},
        ("/api/v1/query", "c"): {"data": {"result": [{"metric": {}, "value": [1, "NaN"]}]}},
    })
    p = Prom("http://prom", fetch)
    assert p.query("a", 10) == 2.5
    assert p.query("b", 10) is None
    assert p.query("c", 10) is None
    assert calls[0] == ("/api/v1/query", {"query": "a", "time": 10})


def test_vector_maps_label_sets_to_values():
    fetch, _ = fake({("/api/v1/query", "v"): {"data": {"result": [
        {"metric": {"job": "api-gateway"}, "value": [1, "100"]}, {"metric": {"job": "problem-service"}, "value": [1, "NaN"]}]}}})
    assert Prom("http://prom", fetch).vector("v", 1) == {"job=api-gateway": 100.0, "job=problem-service": None}


def test_range_keys_series_by_labels_and_turns_nan_into_none():
    fetch, _ = fake({("/api/v1/query_range", "q"): {"data": {"result": [
        {"metric": {"route": "history"}, "values": [[1, "0.1"], [6, "NaN"]]},
        {"metric": {}, "values": [[1, "3"]]}]}}})
    assert Prom("http://prom", fetch).range("q", 0, 10) == {"route=history": [(1.0, 0.1), (6.0, None)], "value": [(1.0, 3.0)]}


def test_label_values_lists_a_label_of_a_series():
    calls = []

    def fetch(path, params):
        calls.append((path, params))
        return {"data": ["0.5", "30.0", "+Inf"]}

    assert Prom("http://prom", fetch).label_values("le", "oj_judge_latency_seconds_bucket") == ["0.5", "30.0", "+Inf"]
    assert calls == [("/api/v1/label/le/values", {"match[]": "oj_judge_latency_seconds_bucket"})]
