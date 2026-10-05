"""The PromQL every figure comes from (spec §5) — one place, so each number says which query made it."""


def judge_quantile(q, window_s):
    return f"histogram_quantile({q}, sum by (le) (increase(oj_judge_latency_seconds_bucket[{window_s}s])))"


def verdict_count(window_s):
    # The latency timer records every applied verdict; oj_verdict_total{status} only exists once a status occurred.
    return f"sum(increase(oj_judge_latency_seconds_count[{window_s}s]))"


def throughput(window_s=30):
    return f"sum(rate(oj_judge_latency_seconds_count[{window_s}s]))"


def max_over(query, window_s):
    return f"max_over_time(({query})[{window_s}s:5s])"


QUEUE_DEPTH = "max(oj_queue_depth)"
VERDICT_LAG = 'max(kafka_consumer_fetch_manager_records_lag_max{job="submission-service"})'
BREAKER_OPEN = 'max(resilience4j_circuitbreaker_state{name="problem-service", state="open"})'
OUTBOX_AGE = "max(oj_outbox_oldest_age_seconds)"
HEAP_BY_JOB = 'sum by (job) (jvm_memory_used_bytes{area="heap"})'
ALERTS_FIRING = 'max by (alertname) (ALERTS{alertstate="firing"})'   # the bench Prometheus evaluates alerts.yml


def k6_p95_by_route(testid):
    return f'max by (route) (k6_http_req_duration_p95{{testid="{testid}"}})'


def series_for(testid):
    """The time series exported for every run: file name → query."""
    return {
        "queue_depth": QUEUE_DEPTH,
        "throughput": throughput(),
        "judge_p95": judge_quantile(0.95, 60),
        "verdict_lag": VERDICT_LAG,
        "breaker_open": BREAKER_OPEN,
        "outbox_age": OUTBOX_AGE,
        "heap": HEAP_BY_JOB,
        "alerts": ALERTS_FIRING,
        "k6_p95": k6_p95_by_route(testid),
    }
