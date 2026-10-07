# E3 — sustained mixed load

Runs: 3. Each cell: median (min–max) over the runs. Runs with dropped iterations: 0 of 3 (k6 could not start an arrival on time).

| route | p50 ms | p95 ms | p99 ms | n | errors % |
|---|---|---|---|---|---|
| problem_list | 4.6 (4.5–5.3) | 8.3 (8.3–9.9) | 10.3 (9.7–12.3) | 6001 (6001–6001) | 0.00 (0.00–0.00) |
| problem_detail | 4.2 (4.1–4.9) | 7.8 (7.8–9.3) | 9.6 (9.2–12.4) | 6000 (6000–6000) | 0.00 (0.00–0.00) |
| history | 4.5 (4.3–5.2) | 8.1 (8.0–9.8) | 10.5 (10.3–12.1) | 6000 (6000–6000) | 0.00 (0.00–0.00) |
| submit | 14.1 (13.2–16.7) | 23.3 (22.1–29.2) | 24.7 (22.8–33.2) | 541 (540–541) | 0.00 (0.00–0.00) |

| measure | value |
|---|---|
| judge latency p95, s (n) | 0.93 (0.89–1.00) (540 (540–540)) |
| SYSTEM_ERROR submissions | 0 (0–0) |
| verdict consumer lag, max | 0 (0–0) |
| outbox oldest age, max, s | 0.0 (0.0–0.0) |
| heap max, job=api-gateway, MB | 75 (75–76) |
| heap max, job=identity-service, MB | 104 (103–105) |
| heap max, job=problem-service, MB | 111 (109–112) |
| heap max, job=submission-service, MB | 123 (120–123) |
