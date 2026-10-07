# E4 — resilience

Runs: 18. Each cell: median (min–max) over the runs. Runs with dropped iterations: 0 of 18 (k6 could not start an arrival on time).

| fault | route | errors during % | first error after inject, s | first success after removal, s | queue back, s | breaker open after, s | alerts firing, s after inject | invariant | SYSTEM_ERROR |
|---|---|---|---|---|---|---|---|---|---|
| c1 | history | 0.0 (0.0–0.0) | — | 0.2 (0.1–0.2) | 3 (3–3) | 9 (9–14) | ProblemServiceCircuitOpen 74 (69–74); ProblemServiceDown 69 (69–74) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 99.0 (99.0–99.5) | 0.6 (0.6–0.7) | 13.1 (13.1–13.9) |  | | | |  |
|  | problem_list | 99.0 (99.0–99.5) | 0.8 (0.6–0.8) | 13.1 (13.1–13.9) |  | | | |  |
|  | submit | 100.0 (100.0–100.0) | 0.8 (0.8–1.2) | 22.8 (21.6–24.5) |  | | | |  |
| c2 | history | 0.0 (0.0–0.0) | — | 0.1 (0.1–0.2) | 53 (49–54) | — | none | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.0 (0.0–0.1) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.2 (0.2–0.3) |  | | | |  |
|  | submit | 0.0 (0.0–0.0) | — | 0.1 (0.1–1.2) |  | | | |  |
| c3 | history | 0.0 (0.0–0.0) | — | 0.3 (0.0–0.3) | 4 (4–5) | — | none | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.2 (0.2–0.2) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.1 (0.1–0.1) |  | | | |  |
|  | submit | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.3) |  | | | |  |
| c4 | history | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.3) | 54 (54–54) | — | none | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.2 (0.0–0.2) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.1 (0.1–0.2) |  | | | |  |
|  | submit | 0.0 (0.0–0.0) | — | 1.0 (1.0–1.2) |  | | | |  |
| c5 | history | 99.0 (99.0–99.0) | 0.7 (0.6–0.8) | 15.9 (15.2–16.8) | 23 (18–23) | — | SubmissionServiceDown 64 (64–69) | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.2) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.2) |  | | | |  |
|  | submit | 97.3 (97.3–97.3) | 4.0 (3.9–4.1) | 16.4 (16.2–17.8) |  | | | |  |
| c6 | history | 0.0 (0.0–0.0) | — | 0.1 (0.1–0.2) | 4 (4–5) | — | none | 3/3 | 0.0 (0.0–0.0) |
|  | problem_detail | 0.0 (0.0–0.0) | — | 0.1 (0.0–0.3) |  | | | |  |
|  | problem_list | 0.0 (0.0–0.0) | — | 0.2 (0.2–0.3) |  | | | |  |
|  | submit | 0.0 (0.0–0.0) | — | 0.1 (0.0–1.7) |  | | | |  |
