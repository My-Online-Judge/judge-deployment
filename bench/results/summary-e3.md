# E3 — sustained mixed load

Runs: 3. Each cell: median (min–max) over the runs. Runs with dropped iterations: 0 of 3 (k6 could not start an arrival on time).

| route | p50 ms | p95 ms | p99 ms | n | errors % |
|---|---|---|---|---|---|
| problem_list | 5.7 (5.4–5.8) | 8.8 (8.7–10.2) | 11.3 (10.6–11.8) | 6001 (6001–6001) | 0.00 (0.00–0.00) |
| problem_detail | 5.4 (5.3–5.9) | 8.2 (8.1–9.5) | 10.4 (9.5–11.5) | 6000 (6000–6000) | 0.00 (0.00–0.00) |
| history | 5.9 (5.4–5.9) | 8.7 (8.5–10.2) | 11.5 (10.6–12.3) | 6000 (6000–6000) | 0.00 (0.00–0.00) |
| submit | 14.5 (14.1–20.8) | 23.5 (22.0–32.2) | 27.9 (25.1–35.7) | 541 (541–541) | 0.00 (0.00–0.00) |

| measure | value |
|---|---|
| judge latency p95, s (n) | 0.83 (0.80–0.87) (540 (540–541)) |
| SYSTEM_ERROR submissions | 0 (0–0) |
| verdict consumer lag, max | 0 (0–0) |
| outbox oldest age, max, s | 0.0 (0.0–0.0) |
| heap max, job=api-gateway, MB | 77 (77–78) |
| heap max, job=identity-service, MB | 105 (104–106) |
| heap max, job=problem-service, MB | 111 (109–112) |
| heap max, job=submission-service, MB | 120 (117–121) |
