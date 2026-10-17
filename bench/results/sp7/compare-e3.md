| route | p50, ms | p95, ms | within range |
|---|---|---|---|
| problem_list | 4.6 (4.5–5.3) → 5.1 | 8.3 (8.3–9.9) → 8.8 | yes |
| problem_detail | 4.2 (4.1–4.9) → 4.8 | 7.8 (7.8–9.3) → 8.2 | yes |
| history | 4.5 (4.3–5.2) → 5.9 | 8.1 (8.0–9.8) → 10.2 | no |
| submit | 14.1 (13.2–16.7) → 16.6 | 23.3 (22.1–29.2) → 26.0 | yes |

Targets (spec §6), over the re-measured runs:

- PASS no alert fired in any run (none)
- PASS problem_list: median p50 and p95 ≤ 1.1 × the before runs' highest
- PASS problem_detail: median p50 and p95 ≤ 1.1 × the before runs' highest
- MISS history: median p50 and p95 ≤ 1.1 × the before runs' highest
- PASS submit: median p50 and p95 ≤ 1.1 × the before runs' highest
