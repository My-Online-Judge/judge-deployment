from oj_analyze import promql


def test_judge_quantile_reads_the_histogram_increase_over_the_window():
    assert promql.judge_quantile(0.95, 180) == \
        "histogram_quantile(0.95, sum by (le) (increase(oj_judge_latency_seconds_bucket[180s])))"


def test_verdicts_are_counted_from_the_latency_timer():
    # oj_verdict_total{status} is created lazily per status; the timer counts every applied verdict from the start.
    assert promql.verdict_count(180) == "sum(increase(oj_judge_latency_seconds_count[180s]))"


def test_max_over_wraps_an_aggregation_in_a_subquery():
    assert promql.max_over("max(oj_queue_depth)", 60) == "max_over_time((max(oj_queue_depth))[60s:5s])"


def test_the_verdict_lag_is_the_submission_service_consumer():
    assert promql.VERDICT_LAG == 'max(kafka_consumer_fetch_manager_records_lag_max{job="submission-service"})'


def test_every_run_exports_the_same_series_with_its_own_testid():
    s = promql.series_for("20261005-120000-e2-w1")
    assert set(s) == {"queue_depth", "throughput", "judge_p95", "verdict_lag", "breaker_open", "outbox_age", "heap", "alerts", "k6_p95"}
    assert 'testid="20261005-120000-e2-w1"' in s["k6_p95"]
