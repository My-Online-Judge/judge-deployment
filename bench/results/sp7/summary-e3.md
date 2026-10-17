# E3 — sustained mixed load

Runs: 1. Each cell: median (min–max) over the runs. Runs with dropped iterations: 0 of 1 (k6 could not start an arrival on time).

| route | p50 ms | p95 ms | p99 ms | n | errors % |
|---|---|---|---|---|---|
| problem_list | 5.1 | 8.8 | 10.5 | 6001 | 0.00 |
| problem_detail | 4.8 | 8.2 | 10.1 | 6000 | 0.00 |
| history | 5.9 | 10.2 | 12.0 | 6000 | 0.00 |
| submit | 16.6 | 26.0 | 28.4 | 541 | 0.00 |

| measure | value |
|---|---|
| judge latency p95, s (n) | 0.89 (540) |
| SYSTEM_ERROR submissions | 0 |
| verdict consumer lag, max | 0 |
| outbox oldest age, max, s | 0.0 |
| heap max, job=api-gateway, MB | 76 |
| heap max, job=identity-service, MB | 106 |
| heap max, job=problem-service, MB | 109 |
| heap max, job=submission-service, MB | 120 |
