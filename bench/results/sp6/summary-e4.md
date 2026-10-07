# E4 — resilience

Runs: 18. Each cell: median (min–max) over the runs. Runs with dropped iterations: 0 of 18 (k6 could not start an arrival on time).

| fault | route | errors during % | first error after inject, s | first success after removal, s | queue back, s | breaker open after, s | alerts firing, s after inject | invariant | SYSTEM_ERROR |
|---|---|---|---|---|---|---|---|---|---|
| c1 | history | 0.0 (0.0–0.0) | — | 0.2 (0.0–0.2) | 4 (2–4) | 10 (9–13) | ProblemServiceCircuitOpen 74 (73–75); ProblemServiceDown 23 (20–24) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 99.0 (99.0–99.5) | 0.8 (0.4–0.8) | 14.4 (14.1–36.9) |  | | | |  |
|  | problem_list | 99.0 (98.5–99.5) | 0.7 (0.3–1.0) | 14.4 (14.1–36.9) |  | | | |  |
|  | submit | 100.0 (100.0–100.0) | 0.9 (0.8–2.0) | 25.5 (25.0–46.0) |  | | | |  |
| c2 | history | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.1) | 55 (50–58) | — | JudgeWorkerDown 28 (25–30) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.2 (0.0–0.3) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.2 (0.1–0.2) |  | | | |  |
|  | submit | 0.0 (0.0–0.0) | — | 1.4 (0.0–1.5) |  | | | |  |
| c3 | history | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.1) | 3 (0–5) | — | SandboxDown 31 (29–35) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.0 (0.0–0.2) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.2 (0.1–0.2) |  | | | |  |
|  | submit | 0.0 (0.0–0.0) | — | 1.3 (0.1–1.6) |  | | | |  |
| c4 | history | 0.0 (0.0–0.0) | — | 0.2 (0.1–0.2) | 63 (53–247) | — | JudgeWorkerDown 59; KafkaUnreachable 49 (19–54) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.1) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.0 (0.0–0.2) |  | | | |  |
|  | submit | 0.0 (0.0–0.0) | — | 0.9 (0.9–1.3) |  | | | |  |
| c5 | history | 99.5 (99.0–99.5) | 0.5 (0.4–0.8) | 17.8 (15.3–42.8) | 24 (19–65) | — | SubmissionServiceDown 21 (20–25) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.2 (0.1–0.2) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.1) |  | | | |  |
|  | submit | 100.0 (97.3–100.0) | 0.8 (0.7–2.1) | 18.6 (16.3–44.1) |  | | | |  |
| c6 | history | 0.0 (0.0–0.0) | — | 0.2 (0.0–0.3) | 4 (3–5) | — | RedisUnavailable 24 (23–25) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.2 (0.1–0.2) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.1) |  | | | |  |
|  | submit | 0.0 (0.0–0.0) | — | 1.3 (1.1–1.6) |  | | | |  |
