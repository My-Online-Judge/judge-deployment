from oj_analyze import stats


def test_summarize_gives_median_and_spread_over_the_runs_that_have_a_number():
    assert stats.summarize([3.0, None, 1.0, 2.0]) == {"median": 2.0, "min": 1.0, "max": 3.0, "runs": 3}


def test_summarize_of_nothing_is_none():
    assert stats.summarize([None, None]) is None
    assert stats.summarize([]) is None


def test_p99_is_reported_only_from_500_samples():
    assert stats.reportable_p99(1.2, 499) is None
    assert stats.reportable_p99(1.2, 500) == 1.2
    assert stats.reportable_p99(1.2, None) is None
    assert stats.reportable_p99(None, 900) is None


def test_a_step_saturates_when_its_backlog_grows_by_more_than_a_tenth_of_its_arrivals():
    assert stats.saturated(10, 30, 180) is True    # +20 > 18
    assert stats.saturated(10, 27, 180) is False   # +17
    assert stats.saturated(None, 27, 180) is False
    assert stats.saturated(0, 5, 0) is False


def test_pilot_steps_bracket_the_capacity_and_stay_under_the_cooldown_limit():
    assert stats.pilot_steps(2.0) == [1.0, 1.5, 2.0, 2.5]
    assert stats.pilot_steps(0.4) == [0.2, 0.3, 0.4, 0.5]
    assert stats.pilot_steps(16) == [8.0, 12.0, 16.0, 18.0]
    assert stats.pilot_steps(0.1) == [0.1]


def test_lag_threshold_is_twice_the_worst_healthy_lag_and_at_least_10():
    assert stats.lag_threshold([0, 3, None, 7]) == 14
    assert stats.lag_threshold([0, 1]) == 10
    assert stats.lag_threshold([]) == 10
    assert stats.lag_threshold([12.5]) == 25


def test_a_quantile_is_censored_when_more_than_its_tail_lies_above_the_top_bucket():
    assert stats.censored(0.06, 0.95) is True
    assert stats.censored(0.05, 0.95) is False
    assert stats.censored(0.02, 0.99) is True
    assert stats.censored(None, 0.95) is False
