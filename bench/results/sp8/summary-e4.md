# E4 — resilience

Runs: 3. Each cell: median (min–max) over the runs. Runs with dropped iterations: 0 of 3 (k6 could not start an arrival on time).

| fault | route | errors during % | first error after inject, s | first success after removal, s | queue back, s | breaker open after, s | alerts firing, s after inject | invariant | SYSTEM_ERROR |
|---|---|---|---|---|---|---|---|---|---|
| c1 | history | 0.0 (0.0–0.0) | — | 0.2 (0.1–0.3) | 2 (2–3) | 14 (13–14) | ProblemServiceCircuitOpen 78 (74–79); ProblemServiceDown 24 (23–29) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 99.0 (99.0–100.0) | 0.7 (0.3–0.7) | 14.2 (13.3–15.0) |  | | | |  |
|  | problem_list | 99.5 (99.0–99.5) | 0.6 (0.5–0.6) | 14.2 (13.3–15.0) |  | | | |  |
|  | submit | 100.0 (97.3–100.0) | 2.2 (2.1–2.4) | 27.2 (25.6–27.6) |  | | | |  |
