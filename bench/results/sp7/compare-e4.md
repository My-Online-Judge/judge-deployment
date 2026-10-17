| fault | route | errors during % | p95 during, ms | p95 overhead, ms | latency recovery, s |
|---|---|---|---|---|---|
| c1 | history | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 12 (10–12) → 12 (11–14) | 1 (-12–1) → 1 (-0–1) | 0 (0–0) → 0 (0–0) |
|  | problem_detail | 99.0 (99.0–99.5) → 99.5 (99.0–99.5) | 6 (6–6) → 6 (6–8) | -2 (-14–-2) → -3 (-6–-2) | 15 (0–15) → 15 (15–20) |
|  | problem_list | 99.0 (98.5–99.5) → 99.5 (99.0–99.5) | 6 (6–7) → 6 (6–8) | -3 (-14–-2) → -3 (-7–-2) | 15 (0–15) → 15 (15–20) |
|  | submit | 100.0 (100.0–100.0) → 100.0 (100.0–100.0) | 2009 (2008–2012) → 2010 (2009–2014) | 1984 (1967–1985) → 1979 (1978–1980) | 30 (25–55) → 25 (25–30) |
| c4 | history | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 10 (10–12) → 10 (10–11) | -0 (-18–1) → 0 (-0–0) | 0 (0–0) → 0 (0–0) |
|  | problem_detail | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 9 (9–10) → 10 (10–10) | 0 (-8–0) → 0 (-0–0) | 0 (0–0) → 0 (0–0) |
|  | problem_list | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 10 (9–10) → 11 (11–11) | 0 (-17–0) → 0 (-1–0) | 0 (0–0) → 0 (0–0) |
|  | submit | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 31 (31–32) → 36 (35–36) | -1 (-19–6) → 6 (5–6) | 0 (0–0) → 0 (0–0) |
| c5 | history | 99.5 (99.0–99.5) → 100.0 (100.0–100.0) | 6 (5–6) → 6 (6–6) | -4 (-12–-3) → -4 (-5–-3) | 20 (0–20) → 20 (20–20) |
|  | problem_detail | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 8 (7–9) → 9 (9–9) | 0 (-12–0) → 0 (-0–0) | 0 (0–0) → 0 (0–0) |
|  | problem_list | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 9 (7–10) → 10 (10–10) | 0 (-9–0) → 0 (-0–1) | 0 (0–0) → 0 (0–0) |
|  | submit | 100.0 (97.3–100.0) → 100.0 (100.0–100.0) | 6 (4–6) → 6 (6–7) | -18 (-21–-13) → -21 (-21–-20) | 20 (0–20) → 20 (20–20) |

| fault | first alert, s after inject | queue back, s | failed dispatches during the fault |
|---|---|---|---|
| c1 | 23 (20–24) → 24 (20–28) | 4 (2–4) → 3 (2–4) | 0 (0–0) → 0 (0–0) |
| c4 | 49 (19–54) → 49 (48–49) | 63 (53–247) → 63 (62–63) | 0 (0–0) → 0 (0–0) |
| c5 | 21 (20–25) → 24 (24–25) | 24 (19–65) → 23 (23–24) | 0 (0–0) → 0 (0–0) |

Targets (spec §6), over the re-measured runs:

- PASS invariant held in 9/9 runs, 0 SYSTEM_ERROR
- PASS c1: first alert ≤ 60 s after inject in every run (28, 20, 24)
- PASS c4: first alert ≤ 60 s after inject in every run (48, 49, 49)
- PASS c5: first alert ≤ 60 s after inject in every run (24, 25, 24)
- PASS c1 problem_list: p95 during < 100 ms (median 6)
- PASS c1 problem_detail: p95 during < 100 ms (median 6)
- MISS c1 submit: p95 during < 500 ms (median 2010)
- PASS c5 history: p95 during < 100 ms (median 6)
- PASS c5 submit: p95 during < 100 ms (median 6)
- PASS c4: JudgeWorkerDown in no run (0 of 3)
- PASS c4: queue back ≤ 70 s in every run (62, 63, 63)
