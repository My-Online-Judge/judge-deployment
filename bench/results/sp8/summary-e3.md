# E3 — sustained mixed load

Runs: 1. Each cell: median (min–max) over the runs. Runs with dropped iterations: 0 of 1 (k6 could not start an arrival on time).

| route | p50 ms | p95 ms | p99 ms | n | errors % |
|---|---|---|---|---|---|
| problem_list | 5.3 | 9.3 | 11.3 | 6001 | 0.00 |
| problem_detail | 5.0 | 8.6 | 10.1 | 6000 | 0.00 |
| history | 4.7 | 8.3 | 9.9 | 6000 | 0.00 |
| submit | 15.8 | 25.9 | 27.7 | 541 | 0.00 |

| measure | value |
|---|---|
| judge latency p95, s (n) | 0.85 (540) |
| SYSTEM_ERROR submissions | 0 |
| verdict consumer lag, max | 0 |
| outbox oldest age, max, s | 0.0 |
| heap max, job=api-gateway, MB | 75 |
| heap max, job=identity-service, MB | 104 |
| heap max, job=problem-service, MB | 109 |
| heap max, job=submission-service, MB | 122 |
