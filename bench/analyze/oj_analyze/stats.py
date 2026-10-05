"""Small statistics the report relies on (spec §3.1, plan P7/P8)."""
import math
from statistics import median

MAX_SUBMIT_RATE = 18.0  # = maxSubmitRate() in k6/lib/pure.js


def summarize(values):
    """Median and min–max over the runs that produced a number; None when none did."""
    xs = [v for v in values if v is not None]
    if not xs:
        return None
    return {"median": median(xs), "min": min(xs), "max": max(xs), "runs": len(xs)}


def reportable_p99(p99, n, min_n=500):
    return p99 if p99 is not None and n is not None and n >= min_n else None


def censored(share_above_top, q):
    """A q-quantile is censored when more than its tail (1 - q) of the observations lies above the histogram's top
    finite bucket: histogram_quantile would return that bucket's bound, not the quantile (review C2)."""
    return share_above_top is not None and share_above_top > 1 - q + 1e-9


def saturated(queue_start, queue_end, arrivals, frac=0.1):
    """A step saturates when its backlog grows by more than frac of what arrived during it."""
    if queue_start is None or queue_end is None or arrivals <= 0:
        return False
    return (queue_end - queue_start) > frac * arrivals


def pilot_steps(capacity):
    """E2's measured steps from a pilot's capacity (verdicts/s): ½, ¾, 1 and 5/4 of it, rounded to 0.1, ≥ 0.1, ≤ 18."""
    steps = {min(MAX_SUBMIT_RATE, max(0.1, round(capacity * f, 1))) for f in (0.5, 0.75, 1.0, 1.25)}
    return sorted(steps)


def lag_threshold(lags, floor=10):
    """E5 (plan P7): twice the highest verdict-consumer lag seen while the system kept up, at least floor."""
    xs = [v for v in lags if v is not None]
    return max(floor, math.ceil(2 * max(xs))) if xs else floor
