# E4 — resilience

Runs: 9. Each cell: median (min–max) over the runs. Runs with dropped iterations: 0 of 9 (k6 could not start an arrival on time).

| fault | route | errors during % | first error after inject, s | first success after removal, s | queue back, s | breaker open after, s | alerts firing, s after inject | invariant | SYSTEM_ERROR |
|---|---|---|---|---|---|---|---|---|---|
| c1 | history | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.3) | 3 (2–4) | 10 (8–14) | ProblemServiceCircuitOpen 73 (70–79); ProblemServiceDown 24 (20–28) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 99.5 (99.0–99.5) | 0.5 (0.5–0.6) | 14.5 (14.5–15.1) |  | | | |  |
|  | problem_list | 99.5 (99.0–99.5) | 0.4 (0.4–0.8) | 14.5 (14.5–15.1) |  | | | |  |
|  | submit | 100.0 (100.0–100.0) | 0.7 (0.5–1.7) | 25.0 (24.4–25.9) |  | | | |  |
| c4 | history | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.2) | 63 (62–63) | — | KafkaUnreachable 49 (48–49) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.2 (0.1–0.3) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.2) |  | | | |  |
|  | submit | 0.0 (0.0–0.0) | — | 1.3 (0.5–1.4) |  | | | |  |
| c5 | history | 100.0 (100.0–100.0) | 0.3 (0.2–0.3) | 17.0 (16.6–17.0) | 23 (23–24) | — | SubmissionServiceDown 24 (24–25) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.2 (0.2–0.2) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.1 (0.1–0.1) |  | | | |  |
|  | submit | 100.0 (100.0–100.0) | 0.6 (0.4–1.6) | 17.6 (17.3–17.9) |  | | | |  |
