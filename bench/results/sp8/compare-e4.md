| fault | route | errors during % | p95 during, ms | p95 overhead, ms | latency recovery, s |
|---|---|---|---|---|---|
| c1 | history | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 12 (11–14) → 11 (10–13) | 1 (-0–1) → 1 (-0–1) | 0 (0–0) → 0 (0–0) |
|  | problem_detail | 99.5 (99.0–99.5) → 99.0 (99.0–100.0) | 6 (6–8) → 6 (6–7) | -3 (-6–-2) → -4 (-5–-3) | 15 (15–20) → 15 (15–15) |
|  | problem_list | 99.5 (99.0–99.5) → 99.5 (99.0–99.5) | 6 (6–8) → 6 (6–7) | -3 (-7–-2) → -5 (-6–-4) | 15 (15–20) → 15 (15–15) |
|  | submit | 100.0 (100.0–100.0) → 100.0 (97.3–100.0) | 2010 (2009–2014) → 110 (108–134) | 1979 (1978–1980) → 80 (76–99) | 25 (25–30) → 30 (30–30) |

| fault | first alert, s after inject | queue back, s | failed dispatches during the fault |
|---|---|---|---|
| c1 | 24 (20–28) → 24 (23–29) | 3 (2–4) → 2 (2–3) | 0 (0–0) → 0 (0–0) |

Targets (spec §6), over the re-measured runs:

- PASS invariant held in 3/3 runs, 0 SYSTEM_ERROR
- PASS c1: first alert ≤ 60 s after inject in every run (23, 29, 24)
- PASS c1 problem_list: p95 during < 100 ms (median 6)
- PASS c1 problem_detail: p95 during < 100 ms (median 6)
- PASS c1 submit: p95 during < 500 ms (median 110)
