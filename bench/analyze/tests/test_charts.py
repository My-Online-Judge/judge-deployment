from oj_analyze import charts

PNG = b"\x89PNG"


def test_a_timeseries_chart_with_a_fault_window_is_a_png(tmp_path):
    path = tmp_path / "q.png"
    charts.timeseries_png(path, {"value": [(100.0, 1.0), (105.0, None), (110.0, 3.0)]}, "Judge queue depth", "submissions", 100.0, [(102.0, 108.0)])
    assert path.read_bytes()[:4] == PNG


def test_a_chart_without_data_is_still_drawn(tmp_path):
    path = tmp_path / "empty.png"
    charts.timeseries_png(path, {}, "Nothing", "x", 0.0)
    assert path.read_bytes()[:4] == PNG


def test_the_capacity_chart_skips_missing_points(tmp_path):
    path = tmp_path / "capacity.png"
    charts.capacity_png(path, {1: [{"rate": 0.5, "throughput": 0.5, "p95": 3.0}, {"rate": 1, "throughput": 0.8, "p95": None},
                                   {"rate": 2, "throughput": 0.8, "p95": 30.0, "p95_censored": True}],
                               2: [{"rate": 1, "throughput": 1.0, "p95": 2.0}]})
    assert path.read_bytes()[:4] == PNG
