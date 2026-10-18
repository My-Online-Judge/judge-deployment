# Sub-project 5 — load and chaos evaluation: report

Every table and chart below comes from a file under `bench/results/` on this branch, and every run can be repeated
from `bench/README.md`. Raw data per run: `run.json` (arguments, commits, image ids), `summary.json` (k6),
`k6.log` (one line per request), `series/*.csv` (Prometheus), `invariant.json`; for C2 and C3 also `worker-log.txt`,
an excerpt of the judge-worker's log. A few observations come from outside the per-run files and say so where they
appear: the host's memory and swap (the campaign's session logs in `bench/results/sessions/`, or read during a
session), the seed's timing (noted during the session) and the host description.
The 16 E2 `summary.json` files were written before the fix that keeps access tokens out of them (`3a595f8`); their
`setup_data` field was removed afterwards by script, and nothing else in them changed.

## 1. Setup

- **Host.** One laptop: Intel Core i7-1165G7 (4 cores, 8 threads, 2.8 GHz base), 11 GB RAM, Linux 7.0.0-34,
  Docker 29.7.2, Compose 5.1.3. The system under test, Prometheus, k6 and the analysis all share it.
- **System under test.** `judge-deployment`'s production Compose file, run as project `oj-bench` with
  `bench/compose.bench.yml`: Prometheus scrapes every 5 s and accepts k6's remote write, `judge-portal` is left
  out, and the five built services run the same images as the live stack (`pull_policy: never`).
- **Versions** (`run.json`). The service commits below and every image id are the same in all 46 run directories (42 measured runs
  and 4 pilots).
  judge-deployment was at `40fcc84` for E2, `20f5c7d` for E1 and E3, and `7abea79` for E4; these three commits
  differ only under `bench/`, through the harness fixes made on this branch.

  | repository | commit |
  |---|---|
  | judge-deployment | `40fcc84` |
  | oj-common | `ad10a26` |
  | oj-api-gateway | `01ee0ff` |
  | oj-identity-service | `9372f23` |
  | oj-problem-service | `0f9a8b1` |
  | oj-submission-service | `4f7163a` |
  | judge-worker | `c748655` |

- **Configuration.** 2 sandboxes (`judge-server`, `judge-server-2`); 6 partitions on `submission.requested`;
  a per-user submit cooldown of 10 s, so the 200 bench users allow at most 20 submissions/s (the harness refuses
  rates above 90 % of that, 18/s); the reconcile job
  turns a submission still PENDING or JUDGING after 5 minutes into SYSTEM_ERROR.
- **Load generator.** k6 2.3.0 (pinned by digest), `--cpus 1`, on `oj-net`, every request through the gateway.
- **Data.** 200 users `bench_u001…bench_u200`; problems `bench-ab` (A + B) and `bench-sum`, 5 test cases each.
  Every seed submits the reference solutions in C++ and Python 3 and refuses to go on unless all four are
  ACCEPTED.

## 2. Method

- Open model: k6 `constant-arrival-rate` / `ramping-arrival-rate`, so a slow system does not slow the arrivals.
  A run reports the iterations k6 could not start on time (`dropped_iterations`). One run had some (E1, §3); no
  other run did.
- Each measurement runs **3 times**; tables give the median and the min–max spread. The first 60 s of a run are
  warm-up and excluded.
- Every percentile is given with its sample count `n`; a p99 is given only where `n ≥ 500`.
- **Submit → verdict latency** is the server's `oj_judge_latency_seconds` histogram. Its top bucket is 30 s, so a
  quantile that lies above it is printed "≥ 30" (an open marker in the charts) rather than an invented number.
- **Throughput** counts every applied verdict through that timer's `_count`. The per-status verdict counters are
  created lazily, so their first increment is invisible to `increase()`.
- **Accepted submission** means HTTP 200 with a submission id. The **invariant** of every run: each accepted
  submission is found afterwards in a terminal status; SYSTEM_ERROR ids and the status histogram are listed.
- **Drain.** After the load, a run waits until the judge queue is empty *and* the `judge-workers` consumer group
  has no lag on `submission.requested` — the queue gauge alone reads 0 while messages still wait in Kafka.
- **Client latency over time** comes from k6's per-request log lines (millisecond precision). k6's remote-written
  trend statistics are cumulative since the start of the run, so they cannot show a change during it.
- A run that fails is repeated on a re-created stack; a run that leaves the queue undrained or fails its
  invariant is kept, and the stack is re-created before the next one.

## 3. E1 — read latency

Reads at 20, 50 and 100 req/s, spread evenly over the problem list, one problem's detail and the user's
submission history (each user has two judged submissions), 180 s measured after a 60 s warm-up.

Runs: 9. Each cell: median (min–max) over the runs. Runs with dropped iterations: 1 of 9 (k6 could not start an arrival on time).

| req/s | route | p50 ms | p95 ms | p99 ms | n | errors % |
|---|---|---|---|---|---|---|
| 20 | problem_list | 5.7 (4.0–7.9) | 9.1 (8.3–11.6) | 10.6 (9.1–14.4) | 1201 (1200–1201) | 0.00 (0.00–0.00) |
| 20 | problem_detail | 5.4 (3.8–7.4) | 8.5 (7.6–10.8) | 11.5 (8.8–12.4) | 1200 (1200–1200) | 0.00 (0.00–0.00) |
| 20 | history | 5.8 (3.9–7.5) | 8.5 (7.8–11.2) | 9.5 (9.4–12.6) | 1200 (1200–1200) | 0.00 (0.00–0.00) |
| 50 | problem_list | 6.8 (3.8–7.4) | 8.2 (8.1–8.3) | 10.9 (9.7–11.3) | 3001 (3001–3001) | 0.00 (0.00–0.00) |
| 50 | problem_detail | 6.4 (3.7–6.8) | 7.7 (7.6–7.8) | 9.7 (8.6–10.7) | 3000 (3000–3000) | 0.00 (0.00–0.00) |
| 50 | history | 6.4 (3.9–6.9) | 7.8 (7.7–8.2) | 10.1 (8.9–11.2) | 3000 (3000–3000) | 0.00 (0.00–0.00) |
| 100 | problem_list | 3.0 (2.9–3.0) | 5.2 (4.7–7.5) | 9.8 (7.0–15.5) | 6001 (5715–6001) | 0.00 (0.00–0.00) |
| 100 | problem_detail | 2.8 (2.6–2.8) | 5.7 (4.8–7.2) | 9.5 (6.5–16.4) | 6000 (5714–6000) | 0.00 (0.00–0.00) |
| 100 | history | 2.9 (2.8–2.9) | 5.1 (4.9–7.3) | 9.5 (6.6–13.8) | 6000 (5714–6000) | 0.00 (0.00–0.00) |

- **No errors at any rate, p95 at or under 10 ms** (median of the runs). At 100 req/s the read path is far from
  saturated on this host. The figures are end to end: gateway hop, JWT check, the owning service and its
  database. Splitting them per hop needs trace sampling (follow-up 8.4).
- **Latency is lowest at the highest rate** (p50 5.4–6.8 ms at 20 and 50 req/s, 2.8–3.0 ms at 100 req/s). This is
  consistent with CPU power states on a mostly idle laptop, where cores sleep between requests at low rates. Not
  investigated.
- **One stall.** Run `20261007-102621-e1-r100` dropped 858 arrivals (n = 5,715 instead of 6,000 per route)
  around a single 9 s pause in the measured window. The host had 3.9 of its 4 GB swap in use (read during the session, not
  logged), so swapping is the likely cause; the bench stack's logs went with it, so it cannot be confirmed. The run is kept in the table.

## 4. E2 — judging capacity

`bench-sum` submissions, alternating C++ and Python 3, in four 3-minute steps per worker count after a 60 s
warm-up. The steps were fixed from one pilot per worker count (pilot steps 0.5, 1, 1.5, 2 × workers per second,
60 s each; measured steps = pilot capacity × 0.5, 0.75, 1, 1.25).

Runs: 12. Each cell: median (min–max) over the runs. Runs with dropped iterations: 0 of 12 (k6 could not start an arrival on time).

| workers | target/s | measured/s | verdicts/s | p50 s | p95 s | p99 s | n | saturated runs |
|---|---|---|---|---|---|---|---|---|
| 1 | 0.5 | 0.50 (0.50–0.50) | 0.50 (0.50–0.50) | 0.72 (0.72–0.75) | 0.85 (0.83–1.22) | — | 91 (89–91) | 0/3 |
| 1 | 0.8 | 0.80 (0.80–0.80) | 0.80 (0.80–0.80) | 0.72 (0.72–0.73) | 0.85 (0.84–0.85) | — | 144 (144–144) | 0/3 |
| 1 | 1.1 | 1.10 (1.10–1.10) | 1.10 (1.10–1.10) | 0.72 (0.72–0.75) | 0.86 (0.84–1.05) | — | 197 (197–199) | 0/3 |
| 1 | 1.3 | 1.30 (1.30–1.30) | 1.28 (1.13–1.30) | 0.82 (0.76–1.39) | 3.57 (1.39–14.53) | — | 230 (203–233) | 1/3 |
| 2 | 0.9 | 0.90 (0.90–0.90) | 0.90 (0.90–0.90) | 0.72 (0.72–0.72) | 0.82 (0.80–0.82) | — | 163 (163–163) | 0/3 |
| 2 | 1.3 | 1.30 (1.30–1.30) | 1.30 (1.30–1.30) | 0.74 (0.73–0.74) | 0.89 (0.87–0.92) | — | 235 (233–235) | 0/3 |
| 2 | 1.7 | 1.70 (1.70–1.70) | 1.70 (1.70–1.70) | 1.50 (1.36–1.62) | 3.31 (2.83–3.59) | — | 305 (305–307) | 0/3 |
| 2 | 2.2 | 2.20 (2.20–2.20) | 1.82 (1.81–1.82) | 11.64 (11.27–16.37) | ≥ 30 | ≥ 30 | 327 (326–328) | 3/3 |
| 4 | 1 | 1.00 (1.00–1.00) | 1.00 (1.00–1.00) | 0.72 (0.72–0.72) | 0.83 (0.83–0.85) | — | 180 (180–180) | 0/3 |
| 4 | 1.5 | 1.50 (1.50–1.50) | 1.50 (1.50–1.50) | 0.85 (0.81–0.86) | 1.36 (1.30–1.36) | — | 269 (269–269) | 0/3 |
| 4 | 2 | 2.00 (2.00–2.00) | 1.99 (1.97–2.00) | 1.81 (1.76–2.22) | 5.71 (3.83–6.76) | — | 358 (354–360) | 0/3 |
| 4 | 2.5 | 2.50 (2.50–2.50) | 2.07 (2.03–2.09) | 10.10 (8.23–13.04) | ≥ 30 | ≥ 30 | 372 (366–375) | 3/3 |
| 6 | 1.1 | 1.10 (1.10–1.10) | 1.10 (1.10–1.10) | 0.72 (0.72–0.75) | 0.86 (0.84–1.01) | — | 199 (197–199) | 0/3 |
| 6 | 1.6 | 1.60 (1.60–1.60) | 1.59 (1.59–1.60) | 0.85 (0.84–0.86) | 1.35 (1.24–1.38) | — | 287 (287–288) | 0/3 |
| 6 | 2.1 | 2.10 (2.10–2.10) | 2.10 (2.09–2.10) | 1.55 (1.54–1.77) | 2.99 (2.96–3.24) | — | 377 (376–379) | 0/3 |
| 6 | 2.6 | 2.60 (2.60–2.60) | 2.20 (2.20–2.22) | 11.75 (11.74–12.67) | ≥ 30 | ≥ 30 | 396 (396–399) | 3/3 |

| workers | capacity, verdicts/s (median of the runs' best step) | highest unsaturated step, /s | SYSTEM_ERROR per run |
|---|---|---|---|
| 1 | 1.28 | 1.3 | 0 (0–0) |
| 2 | 1.82 | 1.7 | 0 (0–0) |
| 4 | 2.07 | 2 | 0 (0–0) |
| 6 | 2.20 | 2.1 | 0 (0–0) |

![Judging throughput and p95 against the arrival rate](results/capacity.png)

**Well below capacity the latency is the cost of one judgement, not of queueing.** At every worker count the
lowest step shows p50 0.72 s and p95 0.82–0.86 s: the time to compile and run five tests. Near capacity queueing
already shows while the system still keeps up: at the third step, p95 is 3.0–5.7 s with 2, 4 and 6 workers (0.86 s
with 1 worker). Once arrivals pass capacity, the queue grows for the whole step (open model): p50 jumps to 10–12 s
(median of the runs) and p95 passes the histogram's 30 s ceiling within three minutes.

**Scaling stops after two workers.** Scaling efficiency, capacity(N) / (N × capacity(1)):

| workers | capacity, verdicts/s | efficiency |
|---|---|---|
| 1 | 1.28 | 1.00 |
| 2 | 1.82 | 0.71 |
| 4 | 2.07 | 0.40 |
| 6 | 2.20 | 0.29 |

Going from 4 to 6 workers adds about 6 %. The workers are not the bottleneck past two: every verdict needs one of
the two sandboxes and CPU on a 4-core host that also runs the services, the databases, Kafka and k6. The
campaign did not sample per-container CPU, so it cannot say which of the two limits the plateau (follow-up 8.1).

**The 1-worker capacity is only known to lie between 1.1 and 1.3 verdicts/s.** At 1.3/s two runs kept up and one
delivered 1.13/s; the pilot, overloaded harder (1.5 and 2/s for 60 s), delivered 1.04–1.07/s. Heavier overload
costs throughput: the saturated pilot steps of every worker count delivered 4–19 % less than the measured
capacity. The efficiencies are therefore approximate. With capacity(1) = 1.13 they would be 0.81, 0.46 and 0.33
instead of 0.71, 0.40 and 0.29; the plateau shows either way.

**The language mix probably matters.** A side observation, not a measurement: when the E1 seed submitted 400
`bench-ab` Python 3 solutions, one worker judged them in about 85 s (≈ 4.7/s; noted during the session, not recorded in a file), against 1.28/s for
E2's half-C++ `bench-sum` mix. The problem differs as well as the language, so this does not isolate the C++
compile; a C++-only and a Python-only E2 step would.

## 5. E3 — sustained mixed load

15 minutes at 0.6 submissions/s — half the 1-worker capacity, rounded — plus 20 reads/s, one worker.

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

![Client p95 per route over one E3 run](results/20261007-110214-e3/client_p95.png)
![JVM heap per service over the same run](results/20261007-110214-e3/heap.png)

- **Steady state holds.** Judge p95 stays at 0.83 s (the same as E2 below saturation), the verdict consumer
  never lags, the outbox never holds a message for a measurable time, and every run passes the invariant
  (578 accepted, 0 SYSTEM_ERROR). Heap is a flat sawtooth: no growth over 15 minutes.
- **Submit latency steps down at minute 12.** In all three runs the submit p50 falls from ≈ 19 ms to ≈ 8 ms
  at minute 12 and stays there; the reads do not change. Minute 12 is when the harness replaces every user's
  access token (`RELOGIN_AFTER_MS`). The submit path has no token-keyed cache, so the mechanism is not
  identified (follow-up 8.5). The table's submit percentiles mix both regimes.

## 6. E4 — resilience

Each fault of spec §3.5 on E3's submit rate (0.6 submissions/s) with 10 reads/s and one worker: 120 s steady, the fault held
60 s, then 180 s after the component is started again. `bench/chaos/fault.sh` stops the container (`docker stop`,
SIGTERM with a grace period; for c2 `docker stop --time 0`, a kill) and later starts the same container again.
Times come from k6's per-request log, each request stamped when its response arrived.

| fault | stopped |
|---|---|
| c1 | problem-service |
| c2 | the judge-worker, killed |
| c3 | `judge-server-2`, one of the two sandboxes |
| c4 | Kafka |
| c5 | submission-service |
| c6 | Redis |

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

"Queue back" is the time after the restart until the judge queue is at its pre-fault level again.

Client latency in the minute before the fault and during it, in ms, as the median (min–max) over the three runs. These come
from the responses in `k6.log` whose arrival falls in each window; `problem_detail` behaves like `problem_list`
and is left out.

| fault | route | p50 before | p50 during | p95 during |
|---|---|---|---|---|
| c1 | problem_list | 8 (6–8) | 2004 (2004–2005) | 2005 (2005–2007) |
| c1 | history | 8 (8–10) | 10 (9–11) | 11 (11–14) |
| c1 | submit | 22 (22–28) | 9 (9–11) | 2012 (2010–2015) |
| c2 | problem_list | 8 (6–9) | 10 (10–10) | 11 (11–12) |
| c2 | history | 6 (6–7) | 9 (9–10) | 11 (11–11) |
| c2 | submit | 26 (26–30) | 28 (22–30) | 30 (30–32) |
| c3 | problem_list | 8 (8–8) | 7 (7–8) | 10 (10–10) |
| c3 | history | 7 (6–8) | 7 (6–7) | 10 (10–10) |
| c3 | submit | 23 (23–26) | 24 (23–24) | 27 (26–28) |
| c4 | problem_list | 6 (6–8) | 8 (8–8) | 10 (10–10) |
| c4 | history | 7 (6–7) | 8 (8–9) | 10 (10–10) |
| c4 | submit | 22 (20–22) | 24 (23–27) | 36 (34–37) |
| c5 | problem_list | 7 (4–8) | 8 (7–9) | 10 (9–10) |
| c5 | history | 6 (4–7) | 2003 (2003–2004) | 2005 (2005–2005) |
| c5 | submit | 20 (13–20) | 2004 (2003–2004) | 2005 (2005–2010) |
| c6 | problem_list | 6 (6–7) | 613 (601–639) | 615 (603–641) |
| c6 | history | 8 (7–9) | 615 (603–642) | 618 (606–644) |
| c6 | submit | 24 (24–25) | 1624 (1616–1629) | 1661 (1658–1668) |

**The invariant held under every fault.** In all 18 runs every accepted submission reached a terminal verdict,
none of them SYSTEM_ERROR, and k6 dropped no arrivals. The answers to spec §3.5's questions, fault by fault:

- **C1 — problem-service stopped.** Problem reads fail for the whole outage, each one after 2 s: the gateway
  waits out its upstream connect timeout (`connect-timeout: 2000`) for a container that is gone. Submit needs the
  problem's judge spec over gRPC, so it fails too, but fails fast once the breaker is open (p50 9 ms). The breaker
  opened 9–14 s after the stop. Until then, and on every half-open probe, a submit waits out the 2 s gRPC deadline,
  which is the p95. Verdicts are still applied: history (submission-service only) has no errors, and every
  submission accepted before the stop was judged. Reads recover 13 s after the restart, the time problem-service
  takes to start. Submit recovers about 10 s after the reads, which is the breaker's 10 s wait in the open state
  before it tries again. Both alerts fire at 69–74 s (each has `for: 1m`).

  ![C1: client p95 per route](results/20261007-121304-e4-c1/client_p95.png)

- **C2 — judge-worker killed.** Nothing fails for a user, but judging stops. In run `20261007-121936-e4-c2` the
  kill landed 92 ms after the worker had started judging submission `2f492edd…`. The worker commits a message's
  offset only after publishing its verdict, so after the restart the same message was delivered again and judged.
  The run's `worker-log.txt` shows both starts, and the submission ended ACCEPTED, not SYSTEM_ERROR. In the other
  two runs the kill fell between two submissions: their excerpts show no submission judged twice. The queue is back 49–54 s after the restart, and the backlog explains this:
  60 s of arrivals at 0.6/s is 36 submissions, which one worker drains at a net 1.28 − 0.6 = 0.68/s, about 53 s.

  ![C2: judge queue depth](results/20261007-121936-e4-c2/queue_depth.png)

- **C3 — one sandbox stopped.** No errors, and the judge p95 does not move: its highest value is 0.80–0.87 s during the
  fault, against 0.84–0.86 s in the minute before. The worker starts each judgement on the next sandbox in turn and falls through to the
  other when that one fails. The stopped sandbox's name no longer resolves, so each failure is immediate, even
  though every other submission still tries the stopped sandbox first (`worker-log.txt`: one failure every ≈ 3.3 s).
  The throughput loss cannot be measured in this setup: one worker judges one submission at a time, so at this
  load the second sandbox adds no capacity.

  ![C3: judge p95](results/20261007-122607-e4-c3/judge_p95.png)

- **C4 — Kafka stopped.** Nothing fails for a user. A submit commits its row and its outbox record in one
  transaction, and the outbox holds the record until Kafka is back: the oldest record's age peaks at 58–62 s,
  the whole outage. Judging stops, and the queue drains as in C2 (54 s). The submit p95 is 34–37 ms during the
  fault.

  ![C4: judge queue depth](results/20261007-123244-e4-c4/queue_depth.png)

- **C5 — submission-service stopped.** History and submit fail, each after the gateway's 2 s connect timeout;
  problem reads are untouched. In each run one submit was still accepted within half a second of the stop,
  while the service was shutting down gracefully, and it was judged. Verdicts produced while the service was
  down waited in Kafka and were applied after the restart, so no verdict was lost. Recovery takes 16 s, the
  service's start-up. `SubmissionServiceDown` fired at 64–69 s.

  ![C5: client p95 per route](results/20261007-123921-e4-c5/client_p95.png)

- **C6 — Redis stopped.** Nothing fails, because every Redis lookup fails open by design: the submit cooldown
  (`SubmissionRateLimiter`), the gateway's ban lookup (`AccessBanFilter`) and its token-revocation lookup
  (`RevokedTokenFilter`). The cost is latency. Every request waits out the gateway's 250 ms Redis timeout on
  both lookups and takes about 615 ms in all; the ≈ 115 ms beyond the two timeouts is not explained. A submit
  also waits out submission-service's 1 s timeout, about 1.6 s in all. Once Redis is back, the gateway recovers within 4 s, but submits stay at about 1 s for another 13–48 s.
  That fits the reconnect back-off of submission-service's Redis client, but was not confirmed. Live verdict
  push (SSE) also goes through Redis pub/sub, but the bench has no SSE client, so it was not measured. No alert
  fired.

  ![C6: client p95 per route](results/20261007-124551-e4-c6/client_p95.png)

## 7. E5 — the `KafkaConsumerLagging` threshold

**T = 10.** `KafkaConsumerLagging` now reads `max by (job, client_id)
(kafka_consumer_fetch_manager_records_lag_max{job=~"submission-service|problem-service"}) > 10` for 5 minutes,
instead of `> 0`.

Spec §3.6 set the threshold at the number of messages one worker judges in about 2 minutes (≈ 1.28 × 120 ≈ 154).
The plan replaced that rule (its correction P7): `KafkaConsumerLagging` watches the verdict consumer and
problem-service's statistics consumer, not the judge queue (the Python worker's lag is not exported), so a judging
rate says nothing about the lag it alerts on. The plan's rule instead: twice the highest verdict-consumer lag
(`records_lag_max` of submission-service) seen while the system kept up, that is in E2's unsaturated steps and in
E3, with a floor of 10. All 41 of those values (38 steps, 3 runs) are 0, so the floor applies. The lag was 0 in the
saturated steps too, and in every E4 run. Even C5, which stopped the verdict consumer for a minute, left only the
verdicts of the one or two submissions still queued at the stop waiting for it, since submits failed meanwhile.
At these rates the verdict consumer is never the bottleneck: the backlog builds in front of the judge-worker,
where the queue alerts look. The statistics consumer was not measured (the analysis reads submission-service's
lag only), so the threshold applies to it untested. The measurements can confirm that any sustained lag is
abnormal, but they cannot calibrate the threshold beyond its floor. `alerts_test.yml` pins the boundary: a lag of 10 held for
10 minutes stays silent, and a lag of 11 fires.

## 8. Findings and follow-ups

Recorded, not fixed (spec §1).

1. **Capacity plateau at ≈ 2.1–2.2 verdicts/s** (E2, 4 and 6 workers). Next step: sample per-container CPU
   (cAdvisor or `docker stats`) during an E2 step, then add a third sandbox or move the sandboxes to another host,
   whichever the samples point at.
2. **Overload turns submissions into SYSTEM_ERROR.** The reconcile job fails any submission still waiting after
   5 minutes, and the late verdict is then discarded. The pilots, which overloaded the stack for longer than that,
   lost 326 of 1,410 accepted submissions (4 workers, `20261005-221803-e2-w4-pilot`) and 935 of 2,115
   (6 workers, `20261005-223214-e2-w6-pilot`). Under a sustained backlog the system fails work it would have
   finished. Options: scale the timeout with the queue depth, or reconcile only submissions whose message is no
   longer in Kafka.
3. **The judge-latency histogram ends at 30 s**, so every saturated percentile is censored. Add buckets up to
   5 minutes (the reconcile timeout).
4. **No per-hop breakdown of read latency** (E1). Sample traces in Jaeger during an E1 run to split the
   gateway, the JWT check, the service and its database.
5. **Submit latency halves when the access tokens are replaced** (E3, all three runs, minute 12). Compare
   traces of a submit with a 12-minute-old token and with a fresh one.
6. **A stopped upstream costs every request 2 s** (C1, C5). The gateway waits out its 2 s connect timeout on
   each request to a service that is down, and submission-service waits out its 2 s gRPC deadline until its
   breaker opens, and again on every half-open probe. A user sees a 2 s hang, then a 503. A circuit breaker per
   route in the gateway would answer at once.
7. **A Redis outage silently switches enforcement off and slows every request** (C6). The submit cooldown, the IP
   and device bans and logout (token revocation) all fail open. That is a deliberate choice for availability, but
   the code means that for the length of an outage a logged-out token works again and a banned client gets in,
   with no alert to say so (read from the code; the bench sent no logged-out tokens and no banned clients). Every
   request pays 0.6–1.6 s of timeouts. Options: an alert on Redis (item 9); a breaker
   around the lookups, so that an outage costs one timeout instead of one per request; and a per-lookup decision
   on failing open (cooldown, bans) or closed (revocation).
8. **Submit stays slow for up to 48 s after Redis is back** (C6), while the gateway recovers in 4 s. Check the
   reconnect settings of submission-service's Redis client (Lettuce).
9. **Four of the six faults raise no alert** (C2, C3, C4, C6). No rule covers a judge-worker, a sandbox, Kafka or
   Redis being down, and over a 60 s outage the indirect rules cannot fire either: `OutboxBacklogStale` needs an
   age above 60 s for 2 minutes, and `JudgeQueueStalled` needs 15 minutes. Add availability rules for Kafka and
   Redis (through exporters), and for the worker and the sandboxes, for example on the sandbox heartbeats the
   worker already sends to submission-service.
10. **The worker keeps trying a dead sandbox** (C3): every other judgement starts on it. That cost nothing here
    because the failure is immediate, but a sandbox that hangs instead of disappearing would cost each of those
    judgements its request timeout. Skip a sandbox for a while after it fails.
11. **The `KafkaConsumerLagging` threshold cannot be calibrated by load** (E5): no run, overloaded or faulted,
    showed any verdict-consumer lag. The threshold is the floor, 10; revisit it if production shows lag.

## 9. Threats to validity

- **One shared host.** The system, its dependencies, k6 and Prometheus compete for the same 4 cores; absolute
  numbers are this laptop's, the shapes (plateau, knee) are what carries over. k6 is limited to one CPU.
  The 1-minute load average before a run ranged from 0.5 to 9.9 (`run.json` `loadavg_before`), because a run
  starts as soon as the previous one has drained.
- **Three runs per point.** The spread is shown, but three samples cannot give a confidence interval.
- **Percentile noise at low rates.** `n` is printed with every percentile; p99 only from `n ≥ 500`.
- **k6's remote write is experimental.** Tables take k6's numbers from `summary.json`, not from the remote-written
  series.
- **Thermal and frequency behaviour** of a laptop CPU was not controlled.
- **Memory pressure.** The host's 4 GB swap was nearly full through sessions 2 and 3 (3.8–3.9 GB in use while they ran,
  all 4.0 GB at the end of E4: `bench/results/sessions/session-3.log`), with a browser and other programs also running. The E1 stall is the visible effect;
  smaller ones may be hidden in the spread.
- **E4's scope.** One worker and one load level; each fault is a clean stop held for 60 s. Throughput lost to a
  dead sandbox, a consumer-group rebalance across several workers, network partitions, slow (rather than absent)
  dependencies and full disks were not tested. The fault-window latencies in §6 come from `k6.log` by a one-off
  computation, not from `summarize`, so the analysis package does not regenerate them.

## 10. After the fixes (sub-project 6)

Sub-project 6 fixed what E4 found (§8, items 6–10) and ran E3 (three runs) and E4 (eighteen runs: c1–c6, three
each) again on 2026-10-07, 18:23–21:13, with sub-project 5's parameters (§2, §5, §6). The images were built from
the sub-project 6 commits: oj-common `0ea64b1` (0.4.0), oj-api-gateway `b7b3e6b`, oj-submission-service `0e97f36`,
oj-identity-service `4009c3d`, oj-problem-service `01efb53` and judge-worker `25f8580`. The compose file, the alert
rules and the bench were at judge-deployment `b1680d9`. Each run's `run.json` lists these images by id under
`images`. Its `git` field is misleading for this session (§10.7): for the six service repos it names sub-project 5's
commits. The runs are in `bench/results/sp6/`; the session's log is `bench/results/sessions/sp6-session.log`.

The tables below are copied from `bench/results/sp6/compare-e4.md` and `bench/results/sp6/compare-e3.md`. Both were
produced by `python -m oj_analyze compare`, which reads sub-project 5's committed runs and the new ones through the
same code. Each cell is `before → after`, each side the median (min–max) over its runs. "Before" is the minute
before the fault was injected, and "during" is the fault window. `compare` reproduces §6's fault-window figures
from sub-project 5's runs, so both sides are measured the same way.

`bench/probe.sh` timed a read and a submit while a dependency was down, once before the fixes (sub-project 5's
compose file and images) and once after:

- `bench/results/sessions/sp6-probe-before-dns.log` and `bench/results/sessions/sp6-probe-after-dns.log`, with
  problem-service stopped;
- `bench/results/sessions/sp6-probe-before-redis.log` and `bench/results/sessions/sp6-probe-after-redis.log`, with
  Redis stopped.

### 10.1 What was wrong, and what changed

| E4 finding (§8) | Cause, as the probe showed it | Change |
|---|---|---|
| A stopped service costs 2 s per request (6) | The gateway kept dialling a cached address after Docker's DNS stopped resolving `problem-service`. Reactor Netty keeps an answer for its 600 s TTL, so reads answered 503 only after 2.0 s. | The gateway's resolver keeps an answer at most 1 s and never caches a failed lookup. Connect timeout cut from 2000 to 500 ms. The JVMs' own DNS cache is 1 s, with failed lookups not cached. This is set with Security properties: the runtime image's `java.security` overrides the `-D` flag that was tried first. |
| Redis down: +0.6 s per request, +1.6 s per submit, a 13–48 s tail after it returns (7, 8) | Each request waited out the Redis timeouts. Lettuce's reconnect attempts came 5, 9, 8, 17 and 30 s apart, so submission-service reconnected 10 s after Redis started and the gateway 4 s after. | oj-common 0.4.0. A command sent while Lettuce is disconnected fails at once, so the fail-open path runs without waiting. Reconnect attempts are at most 1 s apart, and the JDK resolves Redis's name. |
| The worker keeps trying a dead sandbox (10) | Dispatch started at a round-robin offset and ignored what the ping thread knew. | A health table, fed by the pings and by failed dispatches. Healthy sandboxes are tried first and marked ones last. |
| No alert for four of the six faults; the two that fired did so after the fault (9) | The worker had no metrics. No rule watched the sandboxes, Kafka or Redis, and `*ServiceDown` waited `for: 1m`. | `/metrics` on the worker. New rules `JudgeWorkerDown`, `SandboxDown`, `KafkaUnreachable` and `RedisUnavailable`. `*ServiceDown` now waits `for: 15s`. |
| Found while planning: Redis lost the logout blocklist and revocation cutoffs on every `down`/`up` | No persistence | An append-only file on a named volume |

**The probes after the fixes:**

- **problem-service stopped:** reads through the gateway answered 503 in 4–10 ms. The first took 0.52 s, the new
  connect timeout.
- **Redis down:** a read took 10–30 ms and a submit 22–40 ms. After Redis started, the gateway reconnected in 1.1 s
  and submission-service in 2.4 s.

One cause sat deeper than the spec put it. A submit during c1 still took 2.05 s after the fix.
submission-service's gRPC channel to problem-service has the address `static://problem-service:9090` and keeps
dialling the old address, which no DNS setting reaches (§10.5).

### 10.2 Detection

| fault | first alert, s after inject | queue back, s | failed dispatches during the fault |
|---|---|---|---|
| c1 | 69 (69–74) → 23 (20–24) | 3 (3–3) → 4 (2–4) | — → 0 (0–0) |
| c2 | — → 28 (25–30) | 53 (49–54) → 55 (50–58) | — → 0 (0–0) |
| c3 | — → 31 (29–35) | 4 (4–5) → 3 (0–5) | — → 1 (1–1) |
| c4 | — → 49 (19–54) | 54 (54–54) → 63 (53–247) | — → 0 (0–0) |
| c5 | 64 (64–69) → 21 (20–25) | 23 (18–23) → 24 (19–65) | — → 0 (0–0) |
| c6 | — → 24 (23–25) | 4 (4–5) → 4 (3–5) | — → 0 (0–0) |

**Every fault now raises an alert while it lasts.** Before, four of the six faults raised none, and the other two
alerted after the 60 s fault had ended. In every run the first alert to fire was the fault's own rule
(`results.json`, `alerts_after_s`), and no rule fired that the fault did not explain:

- **c1:** `ProblemServiceDown` at 20–24 s. `ProblemServiceCircuitOpen` followed at 73–75 s; its `for: 1m` is
  unchanged.
- **c2:** `JudgeWorkerDown` at 25–30 s.
- **c3:** `SandboxDown` at 29–35 s. The worker pings each sandbox every 10 s, and a ping or a failed dispatch
  marks the sandbox down. The rule then waits 15 s.
- **c4:** `KafkaUnreachable` at 19–54 s. This rule watches the consumers' connection count and fires once it has
  been 0 for 15 s. The count reached 0 at different times after Kafka stopped, which explains the spread. In run
  `20261007-201205-e4-c4`, `JudgeWorkerDown` also fired, at 59 s, because the worker itself went down (§10.3).
- **c5:** `SubmissionServiceDown` at 20–25 s.
- **c6:** `RedisUnavailable` at 23–25 s.

These times are the bench's. It evaluates rules every 5 s and live every 15 s, so live alerts later (§10.7).

**Failed dispatches.** Under c3, each run recorded exactly one failed dispatch, the one that marks the sandbox
down. Sub-project 5's worker exported no metrics, so its side reads "—". Its `worker-log.txt` showed one failure
every ≈ 3.3 s (§6), about 18 over the minute.

**Queue back.** This column changed little, with two exceptions:

- **c4:** one run took 247 s, explained in §10.3.
- **c5:** one run took 65 s, but c5's queue never held more than two submissions. That range is the queue
  flickering between 0 and 2, not a backlog.

### 10.3 Failing fast, recovering fast

| fault | route | errors during % | p95 during, ms | p95 overhead, ms | latency recovery, s |
|---|---|---|---|---|---|
| c1 | history | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 11 (11–14) → 12 (10–12) | 0 (-3–1) → 1 (-12–1) | 0 (0–0) → 0 (0–0) |
|  | problem_detail | 99.0 (99.0–99.5) → 99.0 (99.0–99.5) | 2005 (2005–2006) → 6 (6–6) | 1996 (1993–1997) → -2 (-14–-2) | 15 (15–15) → 15 (0–15) |
|  | problem_list | 99.0 (99.0–99.5) → 99.0 (98.5–99.5) | 2005 (2005–2007) → 6 (6–7) | 1996 (1992–1996) → -3 (-14–-2) | 15 (15–15) → 15 (0–15) |
|  | submit | 100.0 (100.0–100.0) → 100.0 (100.0–100.0) | 2012 (2010–2015) → 2009 (2008–2012) | 1983 (1980–1985) → 1984 (1967–1985) | 25 (25–25) → 30 (25–55) |
| c2 | history | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 11 (11–11) → 11 (9–11) | 0 (0–0) → 0 (-8–0) | 0 (0–0) → 0 (0–0) |
|  | problem_detail | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 10 (10–10) → 10 (10–10) | 0 (-0–0) → 0 (-9–0) | 0 (0–0) → 0 (0–0) |
|  | problem_list | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 11 (11–12) → 11 (10–11) | 0 (-0–0) → -0 (-11–-0) | 0 (0–0) → 0 (0–0) |
|  | submit | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 30 (30–32) → 29 (26–32) | -0 (-1–0) → -1 (-12–1) | 0 (0–0) → 0 (0–0) |
| c3 | history | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 10 (10–10) → 10 (9–19) | -0 (-0–0) → 0 (0–0) | 0 (0–0) → 0 (0–0) |
|  | problem_detail | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 9 (9–10) → 9 (9–15) | 0 (-0–0) → -0 (-0–0) | 0 (0–0) → 0 (0–0) |
|  | problem_list | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 10 (10–10) → 10 (10–17) | -0 (-0–0) → 0 (-0–3) | 0 (0–0) → 0 (0–0) |
|  | submit | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 27 (26–28) → 26 (25–28) | -1 (-1–-0) → 0 (-0–4) | 0 (0–0) → 0 (0–0) |
| c4 | history | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 10 (10–10) → 10 (10–12) | 0 (0–0) → -0 (-18–1) | 0 (0–0) → 0 (0–0) |
|  | problem_detail | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 9 (9–9) → 9 (9–10) | 0 (0–0) → 0 (-8–0) | 0 (0–0) → 0 (0–0) |
|  | problem_list | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 10 (10–10) → 10 (9–10) | 0 (0–0) → 0 (-17–0) | 0 (0–0) → 0 (0–0) |
|  | submit | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 36 (34–37) → 31 (31–32) | 8 (7–10) → -1 (-19–6) | 0 (0–0) → 0 (0–0) |
| c5 | history | 99.0 (99.0–99.0) → 99.5 (99.0–99.5) | 2005 (2005–2005) → 6 (5–6) | 1995 (1995–1996) → -4 (-12–-3) | 20 (20–20) → 20 (0–20) |
|  | problem_detail | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 9 (8–9) → 8 (7–9) | 0 (-0–0) → 0 (-12–0) | 0 (0–0) → 0 (0–0) |
|  | problem_list | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 10 (9–10) → 9 (7–10) | 0 (0–0) → 0 (-9–0) | 0 (0–0) → 0 (0–0) |
|  | submit | 97.3 (97.3–97.3) → 100.0 (97.3–100.0) | 2005 (2005–2010) → 6 (4–6) | 1980 (1979–1985) → -18 (-21–-13) | 20 (20–20) → 20 (0–20) |
| c6 | history | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 618 (606–644) → 11 (11–22) | 607 (594–632) → -1 (-4–-0) | 5 (5–5) → 0 (0–0) |
|  | problem_detail | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 615 (603–640) → 8 (7–14) | 606 (594–632) → -1 (-1–-0) | 5 (5–5) → 0 (0–0) |
|  | problem_list | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 615 (603–641) → 8 (8–15) | 606 (594–632) → -1 (-3–-0) | 5 (5–5) → 0 (0–0) |
|  | submit | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 1661 (1658–1668) → 29 (27–64) | 1628 (1628–1638) → -2 (-2–10) | 20 (15–50) → 0 (0–0) |

**How to read the columns:**

- **p95 overhead:** p95 during the fault minus p95 in the minute before. It is negative when the failed requests
  are faster than the normal ones.
- **Latency recovery:** the end of the last slow 5 s window after the component is started again, in seconds. A
  window is slow when its p95 is above twice the p95 before, or above 100 ms if that is larger. Only windows before
  latency has stayed normal for 30 s count, so a lone late outlier is not taken for slow recovery.

The errors column does not move, and that is expected. A stopped service still fails its requests; what changed is
how long each failure takes.

- **C1, problem-service stopped.** Reads now fail in 6 ms instead of 2005 ms. In the figure, only the first 10 s
  window rises, to about 0.5 s: the connect timeout, paid until the cached address expires. Submit did not change
  (p95 2009 ms against 2012 ms), and it has the same pattern as in §6:
  - The breaker opened 9–13 s after the stop. Until then, and on every half-open probe, a submit waited out the 2 s
    gRPC deadline.
  - This is the gRPC channel of §10.1, untouched by the DNS settings.

  Latency recovery after the restart:
  - Reads: 15 s in two runs, problem-service's start-up and its first slow responses. In the third run, no window
    was slow.
  - Submit: 30 s (25–55 s), the breaker's 10 s wait on top of the start-up. The 55 s run was not examined further.

  | before (sub-project 5) | after |
  |---|---|
  | ![C1 before: client p95 per route](results/20261007-121304-e4-c1/client_p95.png) | ![C1 after: client p95 per route](results/sp6/20261007-191232-e4-c1/client_p95.png) |

- **C2, judge-worker killed, and C3, a sandbox stopped.** Unchanged for users, as before. Under C3 the worker now
  stops sending judgements to the stopped sandbox after the first failure (§10.2).
- **C4, Kafka stopped.** Unchanged for users (submit p95 31 ms against 36 ms). The queue was back in 53 and 63 s
  in two runs, as before (54 s). In run `20261007-201205-e4-c4` it took 247 s:
  - The worker's `/metrics` stopped answering during the outage, and `JudgeWorkerDown` fired 59 s after the stop.
  - The worker resumed judging about 45 s later than in the other two runs: the queue peaked at 64 submissions,
    235 s into the run. The other two runs peaked at 37 and 38, at 190 and 195 s.
  - At one worker's net drain rate that backlog took four minutes to clear.
  - The likely cause, read from the code: `worker.py` publishes each verdict with `future.get(timeout=30)` and does
    not catch its failure. A verdict being published when Kafka stops therefore ends the process, and Docker
    restarts the container (`restart: unless-stopped`).
  - Not confirmed: the containers' logs were removed with the bench.
  - No submission was lost. The message's offset had not been committed, so the submission was delivered again: the
    run's invariant shows 217 accepted, none SYSTEM_ERROR.
  - This code did not change in sub-project 6. Sub-project 5's three c4 runs did not show it (54 s each), and its
    worker had no metrics that could have.
- **C5, submission-service stopped.** History and submit now fail in 6 ms instead of 2005 ms. Latency recovery
  (20 s in two runs) is the service's start-up, 16 s in §6.
- **C6, Redis stopped.** Requests no longer pay for the outage:
  - Reads: p95 8–11 ms against 615–618 ms.
  - Submit: 29 ms against 1661 ms.
  - Overhead: −2 to −1 ms.
  - Latency recovery: 0 s in every run, against 5 s for reads and 15–50 s for submits. The tail of §8 item 8 is gone.

  The lookups still fail open, as chosen for sub-project 6. During an outage the cooldown, the bans and logout are
  not enforced, but `RedisUnavailable` now says so within about 25 s.

  | before (sub-project 5) | after |
  |---|---|
  | ![C6 before: client p95 per route](results/20261007-124551-e4-c6/client_p95.png) | ![C6 after: client p95 per route](results/sp6/20261007-194516-e4-c6/client_p95.png) |

  The two figures have different y-axes: before, up to 1750 ms; after, up to 31 ms.

### 10.4 Normal operation (E3)

| route | p50, ms | p95, ms | within range |
|---|---|---|---|
| problem_list | 5.7 (5.4–5.8) → 4.6 (4.5–5.3) | 8.8 (8.7–10.2) → 8.3 (8.3–9.9) | yes |
| problem_detail | 5.4 (5.3–5.9) → 4.2 (4.1–4.9) | 8.2 (8.1–9.5) → 7.8 (7.8–9.3) | yes |
| history | 5.9 (5.4–5.9) → 4.5 (4.3–5.2) | 8.7 (8.5–10.2) → 8.1 (8.0–9.8) | yes |
| submit | 14.5 (14.1–20.8) → 14.1 (13.2–16.7) | 23.5 (22.0–32.2) → 23.3 (22.1–29.2) | yes |

"Within range" means the new median p50 and p95 are at most 1.1 × sub-project 5's highest run. The fixes cost
normal operation nothing. A 1 s DNS cache means more lookups, but the reads' p50 is about 1 ms lower, not higher.
The reason was not examined: the host was less loaded before these runs (§10.7). No alert fired in any of the
three 15-minute runs, so the new rules and the shorter `for` did not raise a false alarm under sustained load.

### 10.5 Targets

The targets of sub-project 6's spec (§6), copied from the two compare files:

- PASS no alert fired in any run (none)
- PASS problem_list: median p50 and p95 ≤ 1.1 × SP5's highest run
- PASS problem_detail: median p50 and p95 ≤ 1.1 × SP5's highest run
- PASS history: median p50 and p95 ≤ 1.1 × SP5's highest run
- PASS submit: median p50 and p95 ≤ 1.1 × SP5's highest run
- PASS invariant held in 18/18 runs, 0 SYSTEM_ERROR
- PASS c1: first alert ≤ 60 s after inject in every run (23, 24, 20)
- PASS c2: first alert ≤ 60 s after inject in every run (28, 25, 30)
- PASS c3: first alert ≤ 60 s after inject in every run (29, 31, 35)
- PASS c4: first alert ≤ 60 s after inject in every run (49, 19, 54)
- PASS c5: first alert ≤ 60 s after inject in every run (25, 21, 20)
- PASS c6: first alert ≤ 60 s after inject in every run (23, 25, 24)
- PASS c1 problem_list: p95 during < 100 ms (median 6)
- PASS c1 problem_detail: p95 during < 100 ms (median 6)
- MISS c1 submit: p95 during < 500 ms (median 2009)
- PASS c5 history: p95 during < 100 ms (median 6)
- PASS c5 submit: p95 during < 100 ms (median 6)
- PASS c6 history: overhead < 20 ms (median -1)
- PASS c6 problem_detail: overhead < 20 ms (median -1)
- PASS c6 problem_list: overhead < 20 ms (median -1)
- PASS c6 submit: p95 during < 100 ms (median 29)
- PASS c6 history: latency recovery < 5 s in every run (0, 0, 0)
- PASS c6 problem_detail: latency recovery < 5 s in every run (0, 0, 0)
- PASS c6 problem_list: latency recovery < 5 s in every run (0, 0, 0)
- PASS c6 submit: latency recovery < 5 s in every run (0, 0, 0)
- PASS c3: at most the one failed dispatch that marks the sandbox down, per run (1, 1, 1)

**24 of 25 met.** The miss is c1's submit: p95 2009 ms, 2008–2012 ms over the three runs, against a target of
500 ms. The spec expected the DNS fix to cut it to the gRPC retries. The after-probe showed why it did not:
submission-service's gRPC channel to problem-service is created with `static://problem-service:9090`. It resolves
the name once and keeps dialling that address, so a request waits out the 2 s gRPC deadline until the breaker
opens, and again on every half-open probe. A fix needs its own design and tests (§10.6, item 12).

### 10.6 Follow-ups

Continuing the numbering of §8. Items 6, 8, 9 and 10 there are fixed, as above. Of item 7, the latency and the
missing alert are fixed, and the lookups still fail open by choice.

12. **A submit still waits 2 s while problem-service is down** (c1, §10.5). Give submission-service's gRPC channel
    a short connect timeout, or move it to `dns:///` name resolution and check how quickly gRPC re-resolves.
    Either way, test it with the c1 probe.
13. **The worker can exit when Kafka goes away** (c4, one run in three, §10.3). Catch a failed verdict publish in
    the worker and retry within the process. Leave the offset uncommitted, as now, so the message is still
    redelivered if the process dies. Test this by stopping Kafka while a verdict is being published.
14. **Every stack start raises critical alerts for about a minute.** On live, the first `down`/`up` after the
    rollout raised `IdentityServiceDown`, `ProblemServiceDown` and `SubmissionServiceDown` while the JVMs started.
    problem-service answered its first scrape about a minute after its container started. All three alerts
    resolved on their own.
    - `JudgeWorkerDown` did not fire, because the worker answers within seconds. The final review had expected
      this rule to be the one that fires.
    - `for: 15s` is far shorter than a JVM's start-up, which is about a minute; the old `for: 1m` was about as long as it.
    - None of this affected the runs here, which start on a running stack.
    - No Alertmanager sends the alerts anywhere yet, so they show only in Prometheus.

    Fix options:
    - a silence or an inhibition in an Alertmanager during a deploy;
    - rules that ignore a target until it has answered once since it started.

    A longer `for` would slow detection again. Whichever fix is chosen, pin it in `alerts_test.yml`.

### 10.7 Threats to validity

- **Detection was measured on the bench.** The bench evaluates rules every 5 s and live every 15 s, so on live a
  rule with `for: 15s` fires up to about 30 s later than shown here (sub-project 6's spec §7).
- **Host load.** Same host, load and parameters as sub-project 5. The host's memory was not logged during this
  session, so §9's memory caveat cannot be checked for it. The 1-minute load average before a run (`run.json`
  `loadavg_before`) ranged from 0.8 to 2.2 for E3 and from 0.7 to 9.1 for E4. In sub-project 5 it ranged from 1.4
  to 4.2 and from 0.5 to 5.6.
- **Sample size.** Each probe ran once before and once after: the probes show the mechanism, and the E4 runs
  measure it. The E4 figures are three runs per fault, so the 247 s of c4 and the 55 s of c1's submit recovery are
  each a single run.
- **No "before" for failed dispatches.** Sub-project 5's worker exported no metrics, so the c3 comparison uses that
  session's worker log, not the same metric.
- **`run.json`'s `git` field.** For the six service repos it names the main checkouts' commits, which were
  sub-project 5's, not the worktrees the images were built from. The bench reads the service repos next to the main
  checkout. The `images` ids in the same file are the sub-project 6 builds named at the top of this section.

## 11. Sub-project 6's follow-ups (sub-project 7)

Sub-project 7 took on follow-ups 12–14 of §10.6. Each one was probed before any change, and the probes decided what
changed. E4's c1, c4 and c5 were then run again (three runs each) together with one E3 run, on 2026-10-17, with the
parameters of §10.

The images were built from:

- oj-submission-service `1282754`: F2 `b4c8e27` and F3 `1282754` below;
- judge-worker `963fb4a`;
- judge-deployment `5d42a30`, which holds the compose file, the rules and the bench.

Each run's `run.json` lists these images by id under `images`: submission-service `0a7d77d759c8` and judge-worker
`50e7e94acae7`; the other three images are sub-project 6's. As in §10.7, its `git` field names the main checkouts'
commits for the service repositories.

The comparison is against sub-project 6's runs of the same faults (`bench/results/sp6/`). The tables are
`bench/results/sp7/compare-e4.md` and `bench/results/sp7/compare-e3.md`. The probes and start checks are in
`bench/results/sessions/`, and the session's log is `bench/results/sessions/sp7-session.log`.

### 11.1 Erratum to §10.5

§10.5 says submission-service's gRPC channel to problem-service has a static address and "keeps dialling the old
address, which no DNS setting reaches". The address is not static:

- Spring gRPC strips the `static:` prefix.
- grpc-java resolves `problem-service:9090` through its default `dns:///` resolver and balances with `round_robin`.
- That resolver keeps an answer for the **system** property `networkaddress.cache.ttl`, 30 s when unset. Sub-project
  6 set a Security property of the same name, which this resolver does not read.

What a submit then waits for was not the resolver either. `bench/results/sessions/sp7-probe-before-grpc.log` timed a
submit every 3 s through a 60 s stop of problem-service:

- Most submits failed in 0.42 s: an `UNAVAILABLE` and two retries 200 ms apart.
- Once the breaker had opened, they failed in about 15 ms.
- Two submits took 2.02 s, at t+20 s and t+50 s. These are the breaker's half-open trials, ten seconds after it
  opened, and they met the 2 s gRPC deadline.

### 11.2 What was wrong, and what changed

| follow-up (§10.6) | what the probe showed | change |
|---|---|---|
| 12: a submit waits 2 s while problem-service is down | Only the breaker's half-open trials wait, and they wait in the channel's buffer: `deadline exceeded after 2.0 s. Name resolution delay 0.000 … buffered_nanos=2.0e9, waiting_for_connection` (`bench/results/sessions/sp7-probe-after-grpc-statuses.log`). The channel was connecting, not failed, when the trial arrived. | Three fixes, each probed (§11.3); none removes the 2 s wait. F1: grpc-java's resolver cache 1 s (`-Dnetworkaddress.cache.ttl=1`). F2: a 500 ms connect timeout on the channel. F3: retries 50 ms apart instead of 200 ms. |
| 13: the worker can exit when Kafka goes away | Kafka killed while a verdict was in flight (`sp7-probe-before-kafka.log`). After 30 s the publish timed out and the worker exited, then crash-looped on `NoBrokersAvailable`: 9 restarts, with Prometheus unable to scrape it. The verdict was terminal 36 s after Kafka's start. | The worker sends the verdict again until Kafka takes it. Meanwhile it pauses its partitions and polls to stay in its group, and it rewinds anything that poll fetches. A verdict Kafka refuses for good is replaced by a SYSTEM_ERROR. At start, the worker waits for a broker instead of exiting. |
| 14: every stack start raises critical alerts | `sp7-startcheck-before.log`: `ApiGatewayDown` 30 s, `IdentityServiceDown` 25 s, `ProblemServiceDown` 30 s and `SubmissionServiceDown` 25 s after Prometheus started. | Prometheus scrapes itself. The five `up`-based rules hold off while it has run under 120 s: `unless on() (time() - process_start_time_seconds{job="prometheus"} <= 120)`. This fails open, so without the self-scrape the rules fire as before. |

### 11.3 Probes and start checks, before and after

**c1 (`probe.sh grpc`).** Each line is a submit's time during a 60 s stop of problem-service.

| step | file | failing submits | half-open trials | gRPC statuses |
|---|---|---|---|---|
| before | `sp7-probe-before-grpc.log` | 0.42 s | 2.02 s (×2) | 2 DEADLINE_EXCEEDED, 4 UNAVAILABLE |
| F1 | `sp7-probe-f1-grpc.log` | 0.42 s | 2.02 s (×2) | same |
| F1+F2 | `sp7-probe-after-grpc.log` | 0.42 s | 2.02 s (×2) | same; the connect now times out after 500 ms |
| F1+F2+F3 | `sp7-probe-f3-grpc.log` | 0.12–0.14 s | 2.02 s (×2) | same |

**c4 (`probe.sh kafka`).** Kafka was killed (SIGKILL) the moment the worker started judging a submission that
sleeps 2.5 s per test.

| | worker restarts | Prometheus scraped the worker | terminal after Kafka's start |
|---|---|---|---|
| before (`sp7-probe-before-kafka.log`) | 0 → 9 | no, from t+41 s | 36 s |
| after (`sp7-probe-after-kafka.log`) | 0 → 0 | yes, throughout | 17 s |

**Stack start (`startcheck.sh`).** Every alert firing in Prometheus's first 180 s:

- before, with sub-project 6's rules (`sp7-startcheck-before.log`): the four `*ServiceDown` rules, at 25–30 s;
- with sub-project 7's rules, on sub-project 6's images (`sp7-startcheck-after-rules.log`): none;
- with sub-project 7's rules and images (`sp7-startcheck-after.log`): none.

### 11.4 E4 (c1, c4, c5) and E3 against sub-project 6

Each cell is `sub-project 6 → sub-project 7`, each side the median (min–max) over its runs. The definitions are §10.3's.

| fault | route | errors during % | p95 during, ms | p95 overhead, ms | latency recovery, s |
|---|---|---|---|---|---|
| c1 | history | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 12 (10–12) → 12 (11–14) | 1 (-12–1) → 1 (-0–1) | 0 (0–0) → 0 (0–0) |
|  | problem_detail | 99.0 (99.0–99.5) → 99.5 (99.0–99.5) | 6 (6–6) → 6 (6–8) | -2 (-14–-2) → -3 (-6–-2) | 15 (0–15) → 15 (15–20) |
|  | problem_list | 99.0 (98.5–99.5) → 99.5 (99.0–99.5) | 6 (6–7) → 6 (6–8) | -3 (-14–-2) → -3 (-7–-2) | 15 (0–15) → 15 (15–20) |
|  | submit | 100.0 (100.0–100.0) → 100.0 (100.0–100.0) | 2009 (2008–2012) → 2010 (2009–2014) | 1984 (1967–1985) → 1979 (1978–1980) | 30 (25–55) → 25 (25–30) |
| c4 | history | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 10 (10–12) → 10 (10–11) | -0 (-18–1) → 0 (-0–0) | 0 (0–0) → 0 (0–0) |
|  | problem_detail | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 9 (9–10) → 10 (10–10) | 0 (-8–0) → 0 (-0–0) | 0 (0–0) → 0 (0–0) |
|  | problem_list | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 10 (9–10) → 11 (11–11) | 0 (-17–0) → 0 (-1–0) | 0 (0–0) → 0 (0–0) |
|  | submit | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 31 (31–32) → 36 (35–36) | -1 (-19–6) → 6 (5–6) | 0 (0–0) → 0 (0–0) |
| c5 | history | 99.5 (99.0–99.5) → 100.0 (100.0–100.0) | 6 (5–6) → 6 (6–6) | -4 (-12–-3) → -4 (-5–-3) | 20 (0–20) → 20 (20–20) |
|  | problem_detail | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 8 (7–9) → 9 (9–9) | 0 (-12–0) → 0 (-0–0) | 0 (0–0) → 0 (0–0) |
|  | problem_list | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 9 (7–10) → 10 (10–10) | 0 (-9–0) → 0 (-0–1) | 0 (0–0) → 0 (0–0) |
|  | submit | 100.0 (97.3–100.0) → 100.0 (100.0–100.0) | 6 (4–6) → 6 (6–7) | -18 (-21–-13) → -21 (-21–-20) | 20 (0–20) → 20 (20–20) |

| fault | first alert, s after inject | queue back, s | failed dispatches during the fault |
|---|---|---|---|
| c1 | 23 (20–24) → 24 (20–28) | 4 (2–4) → 3 (2–4) | 0 (0–0) → 0 (0–0) |
| c4 | 49 (19–54) → 49 (48–49) | 63 (53–247) → 63 (62–63) | 0 (0–0) → 0 (0–0) |
| c5 | 21 (20–25) → 24 (24–25) | 24 (19–65) → 23 (23–24) | 0 (0–0) → 0 (0–0) |

- **c1.** Reads still fail in 6 ms. Submit is unchanged at 2010 ms (2009–2014), against 2009 ms in sub-project 6:
  - The breaker opened 8–14 s after the stop.
  - Its half-open trials wait in the channel for the whole 2 s deadline, as the probes showed.
  - F3 shortened every other failing submit, but those were not the p95.
  - `ProblemServiceDown` fired at 20–28 s.
- **c4.** No run raised `JudgeWorkerDown`, and the queue was back in 62–63 s in every run. In sub-project 6 it took
  53, 63 and 247 s; the 247 s was the run in which the worker exited. These three runs probably did not catch a
  verdict mid-publish, which needs a submission judged at the moment Kafka stops. The kafka probe is the test of that
  path (§11.3). Submit's p95 during the outage, 36 ms, equals sub-project 5's figure in §6.
- **c5.** Unchanged, as expected: history and submit fail in 6 ms, and `SubmissionServiceDown` fired at 24–25 s.

| route | p50, ms | p95, ms | within range |
|---|---|---|---|
| problem_list | 4.6 (4.5–5.3) → 5.1 | 8.3 (8.3–9.9) → 8.8 | yes |
| problem_detail | 4.2 (4.1–4.9) → 4.8 | 7.8 (7.8–9.3) → 8.2 | yes |
| history | 4.5 (4.3–5.2) → 5.9 | 8.1 (8.0–9.8) → 10.2 | no |
| submit | 14.1 (13.2–16.7) → 16.6 | 23.3 (22.1–29.2) → 26.0 | yes |

`history`'s p50 is the one value outside the range: 5.9 ms against 1.1 × 5.2 = 5.73 ms.
- This was one run, and every route in it is about 0.5 ms higher.
- No sub-project 7 change lies on `history`'s path (gateway → submission-service → its database). F2 and F3 touch only
  the gRPC calls to problem-service, and F1 only grpc-java's resolver.
- Sub-project 5's E3 had the same figure (§5: 5.9 ms).

It is reported as a MISS, but it is not a regression the measurements can attribute. No alert fired during the run's
15 minutes.

### 11.5 Targets

From the two compare files, verbatim:

- PASS no alert fired in any run (none)
- PASS problem_list: median p50 and p95 ≤ 1.1 × the before runs' highest
- PASS problem_detail: median p50 and p95 ≤ 1.1 × the before runs' highest
- MISS history: median p50 and p95 ≤ 1.1 × the before runs' highest
- PASS submit: median p50 and p95 ≤ 1.1 × the before runs' highest
- PASS invariant held in 9/9 runs, 0 SYSTEM_ERROR
- PASS c1: first alert ≤ 60 s after inject in every run (28, 20, 24)
- PASS c4: first alert ≤ 60 s after inject in every run (48, 49, 49)
- PASS c5: first alert ≤ 60 s after inject in every run (24, 25, 24)
- PASS c1 problem_list: p95 during < 100 ms (median 6)
- PASS c1 problem_detail: p95 during < 100 ms (median 6)
- MISS c1 submit: p95 during < 500 ms (median 2010)
- PASS c5 history: p95 during < 100 ms (median 6)
- PASS c5 submit: p95 during < 100 ms (median 6)
- PASS c4: JudgeWorkerDown in no run (0 of 3)
- PASS c4: queue back ≤ 70 s in every run (62, 63, 63)

From the probes and start checks (spec §6):

- PASS kafka probe: the worker's restart count unchanged (0 → 0; before: 0 → 9)
- MISS kafka probe: the in-flight submission terminal ≤ 15 s after Kafka's start (17 s; before: 36 s)
- PASS stack start on the bench: no `*ServiceDown` or `JudgeWorkerDown` in the first 180 s (none; before: four)

**16 of 19 met.** The three misses:

- **c1 submit, p95 2010 ms against 500 ms.**
  - Not a resolver cache (F1 changed nothing) and not a hanging connect (F2 changed nothing): the breaker's half-open
    trials wait in the channel's buffer while it is connecting, until the 2 s deadline.
  - What would help is follow-up 15 below.
- **The kafka probe's 17 s.**
  - The probe kills Kafka (SIGKILL), so the 17 s includes Kafka's log recovery, which E4's graceful stop never pays.
  - In a full outage the worker's first wait lasts until the group coordinator answers again (kafka-python 2.0.2 does
    not time out there), then the verdict is sent.
  - One probe; the figure was 36 s with sub-project 6's worker.
- **E3 history p50,** by 0.17 ms in a single run (§11.4).

### 11.6 Follow-ups

Continuing §10.6:

- **Follow-up 12 (a submit waits 2 s while problem-service is down)** is not closed. Its cause is now known; see 15.
- **Follow-up 13 (the worker exits when Kafka goes away)** is closed:
  - the kafka probe: 0 restarts, scraped throughout;
  - E4 c4: no `JudgeWorkerDown` in any run, queue back in 62–63 s.
- **Follow-up 14 (alerts at every stack start)** is closed on the bench (the start checks show none) and on live.
  After the rollout's `up -d` on 2026-10-17, no alert was firing or pending in Prometheus's first 180 s (read during
  the session from live Prometheus's `ALERTS` series).

15. **The breaker's half-open trials wait out the gRPC deadline** (c1). When a trial arrives, the channel is
    connecting again, and grpc-java holds the RPC until the deadline. Options:
    - a shorter per-attempt deadline for these RPCs (they answer in milliseconds; 2 s only bounds the wait);
    - failing a call at once when the channel is not READY (`ManagedChannel.getState(false)`);
    - a breaker that keeps the circuit open while the channel is not READY.

    Each needs the c1 probe and runs before and after.
16. **`oj_verdict_publish_retries_total` counts one or two retries per Kafka outage**, not one per back-off step,
    because the first wait lasts the whole outage. Count outages, or record the time spent waiting, if the metric is
    to mean more.

### 11.7 Threats to validity

- **Bench cadence.** Detection and the start checks were measured on the bench, which evaluates every 5 s; live
  evaluates every 15 s (§10.7).
- **Sample sizes.** E3 is a single run, so it has no spread. E4 has three runs per fault. Each probe ran once per
  step.
- **The kafka probe kills Kafka; E4's c4 stops it.** E4's c4 runs may not catch a verdict mid-publish; the probe
  does, by construction.
- **Host load.** The 1-minute load average before a run (`run.json` `loadavg_before`) was 1.4–3.9 for E4 and 2.1
  for E3, against 0.7–9.1 and 0.8–2.2 in sub-project 6. The host's memory was not logged.
- **`run.json`'s `git` field** names the main checkouts' commits, as in §10.7. The `images` ids are the builds named
  at the top of this section.

## 12. The c1 submit's half-open wait (sub-project 8)

Sub-project 8 took on follow-up 15 of §11.6 (the c1 submit still waited 2 s) and follow-up 16 (what the worker's
resend metric means).

This time the probe watched the gRPC channel itself: the `bench/compose.grpc-trace.yml` overlay turns on grpc-java's
ChannelLogger in submission-service, for the probes only. E4 c1 (three runs) and E3 (one run) were then measured
again on 2026-10-18, without the trace.

The images were built from:

- oj-submission-service `3279a8b`: G1 `5e7b098` and G2 `3279a8b` below;
- judge-worker `18e1d2b`;
- judge-deployment `e9f96dd`.

In each run's `run.json` they are submission-service `b08c8d204d74` and judge-worker `cabcb396b83e`. The tables are
`bench/results/sp8/compare-e4.md` (against sub-project 7's c1 runs) and `bench/results/sp8/compare-e3.md` (against
sub-project 6's three E3 runs and sub-project 7's one).

### 12.1 What the channel trace showed

`bench/results/sessions/sp8-probe-before-grpc.log` (sub-project 7's images) records each 2 s trial and the channel
around it. For the first one:

| time | channel event |
|---|---|
| 20:59:18 | last successful call |
| 20:59:29 | problem-service stopped: TRANSIENT_FAILURE, calls fail fast |
| 20:59:35 | `Failed to resolve name` |
| **20:59:38** | **`Entering IDLE state`**, 20 s after the last call in use |
| 20:59:43 | the old subchannel `Terminated` |
| 20:59:48.3 | the breaker's half-open trial: **`Exiting idle mode`**, a fresh name resolution |
| **20:59:53.3** | **`Entering TRANSIENT_FAILURE`**, 5.0 s later |

Two settings together make the 2 s:

- **Spring gRPC's idle timeout.** The channel has `idleTimeout` 20 s, Spring gRPC 0.12's default (grpc-java's own is
  30 minutes). Calls that fail fast do not keep a channel in use, so while the breaker holds the circuit open the
  channel goes IDLE.
- **A fresh lookup of a stopped container's name.** The next trial takes the channel out of idle mode and starts that
  lookup, which takes 5 s to fail. Meanwhile the trial waits in the channel until its 2 s deadline.

This is why §11's F1 (the resolver cache) and F2 (the connect timeout) changed nothing: no cached answer and no
connect is involved. It also corrects §11.2's reading, "the channel was connecting when the trial arrived": it was
coming out of idle mode.

### 12.2 What changed

- **G1: `pick_first` for the problem-service channel.** There is one problem-service, so `round_robin` gains nothing.
  This alone did not remove the wait: `sp8-probe-g1-grpc.log` shows the same IDLE → exit → 5 s sequence and one
  2.02 s trial. It is kept because the fixes are cumulative and G2 was measured on top of it.
- **G2: `ChannelRecovery`.** It watches the channel's state. From TRANSIENT_FAILURE until READY, it refuses a call at
  once with `UNAVAILABLE` (the breaker counts the refusal) and asks the channel to connect. An IDLE channel after a
  failure therefore resolves in the background instead of in front of a request. A channel that never failed (at
  start-up) is not affected.
- **Not needed:** G3, a shorter per-attempt deadline.
- **The worker (follow-up 16).** `oj_verdict_publish_wait_seconds_total` counts the seconds verdicts waited for
  Kafka. In a full outage the retry counter reads only one or two, because the first wait lasts the whole outage.

### 12.3 The probes, step by step

`probe.sh grpc`: 60 s with problem-service stopped, a submit every 3 s.

| step | file | failing submits | half-open trials | gRPC statuses |
|---|---|---|---|---|
| before | `sp8-probe-before-grpc.log` | 0.12–0.13 s | 2.03 s (×2) | 2 DEADLINE_EXCEEDED, 4 UNAVAILABLE |
| G1 | `sp8-probe-g1-grpc.log` | 0.12–0.13 s | 2.02 s (×1) | 1 DEADLINE_EXCEEDED, 5 UNAVAILABLE |
| G1+G2 | `sp8-probe-g2-grpc.log` | 0.01–0.13 s | refused in 0.12 s | 7 UNAVAILABLE |

With G1+G2, the submit at the stop itself (t+0) took 0.65 s: the 500 ms connect timeout as the container went away.
That is outside the criterion's window, which starts at t+2 s.

After the restart, one submit was refused. At t+15 s the channel had gone IDLE again while problem-service was
still starting, so the submit was refused, and its connection request made the channel READY 110 ms later, just
after the submit's two 50 ms retries. The next submit succeeded. E4's latency-recovery column measures this cost.

`probe.sh kafka` (`sp8-probe-after-kafka.log`):
- the worker's restart count stayed at 0;
- the in-flight submission was terminal 17 s after Kafka started;
- `publish wait: 63.7 s over the outage`, for an outage of about 60 s.

`sp8-startcheck-after.log`: no alert fired in the first 180 s.

### 12.4 E4 c1 against sub-project 7, and E3

| fault | route | errors during % | p95 during, ms | p95 overhead, ms | latency recovery, s |
|---|---|---|---|---|---|
| c1 | history | 0.0 (0.0–0.0) → 0.0 (0.0–0.0) | 12 (11–14) → 11 (10–13) | 1 (-0–1) → 1 (-0–1) | 0 (0–0) → 0 (0–0) |
|  | problem_detail | 99.5 (99.0–99.5) → 99.0 (99.0–100.0) | 6 (6–8) → 6 (6–7) | -3 (-6–-2) → -4 (-5–-3) | 15 (15–20) → 15 (15–15) |
|  | problem_list | 99.5 (99.0–99.5) → 99.5 (99.0–99.5) | 6 (6–8) → 6 (6–7) | -3 (-7–-2) → -5 (-6–-4) | 15 (15–20) → 15 (15–15) |
|  | submit | 100.0 (100.0–100.0) → 100.0 (97.3–100.0) | 2010 (2009–2014) → 110 (108–134) | 1979 (1978–1980) → 80 (76–99) | 25 (25–30) → 30 (30–30) |

| fault | first alert, s after inject | queue back, s | failed dispatches during the fault |
|---|---|---|---|
| c1 | 24 (20–28) → 24 (23–29) | 3 (2–4) → 2 (2–3) | 0 (0–0) → 0 (0–0) |

- **Submit's p95 during the fault:** 110 ms (108–134), against 2010 ms. The failing submits now all fail the same
  way: refused, retried twice 50 ms apart, then 503.
- **Reads, detection, invariant:** unchanged.
- **Submit's latency recovery:** 30 s, against 25 s (25–30). This is the one refused submit after problem-service
  returns (§12.3), followed by the breaker's wait before it tries again.

| route | p50, ms | p95, ms | within range |
|---|---|---|---|
| problem_list | 4.9 (4.5–5.3) → 5.3 | 8.6 (8.3–9.9) → 9.3 | yes |
| problem_detail | 4.5 (4.1–4.9) → 5.0 | 8.0 (7.8–9.3) → 8.6 | yes |
| history | 4.8 (4.3–5.9) → 4.7 | 9.0 (8.0–10.2) → 8.3 | yes |
| submit | 15.4 (13.2–16.7) → 15.8 | 24.7 (22.1–29.2) → 25.9 | yes |

Every route is within 1.1 × the highest of the four earlier runs, and no alert fired. Normal operation does not pay
for the change.

### 12.5 Targets

From the two compare files, verbatim:

- PASS no alert fired in any run (none)
- PASS problem_list: median p50 and p95 ≤ 1.1 × the before runs' highest
- PASS problem_detail: median p50 and p95 ≤ 1.1 × the before runs' highest
- PASS history: median p50 and p95 ≤ 1.1 × the before runs' highest
- PASS submit: median p50 and p95 ≤ 1.1 × the before runs' highest
- PASS invariant held in 3/3 runs, 0 SYSTEM_ERROR
- PASS c1: first alert ≤ 60 s after inject in every run (23, 29, 24)
- PASS c1 problem_list: p95 during < 100 ms (median 6)
- PASS c1 problem_detail: p95 during < 100 ms (median 6)
- PASS c1 submit: p95 during < 500 ms (median 110)

From the probes:

- PASS c1 probe: every submit from t+2 s answers in under 0.5 s (G1+G2: 0.01–0.13 s)
- PASS kafka probe: the worker's restart count unchanged (0 → 0)
- PASS kafka probe: the publish wait over the outage within ±10 s of its length (63.7 s for ~60 s)
- PASS stack start on the bench: no alert in the first 180 s

**14 of 14 met.**

### 12.6 Follow-ups

- **Follow-up 12** (a submit waits 2 s while problem-service is down) and **follow-up 15** (the half-open trials
  wait out the deadline) are closed by G2.
- **Follow-up 16** (the retry counter's meaning) is closed by `oj_verdict_publish_wait_seconds_total`.
- **New, 17:** the first submit after problem-service returns can be refused while its connection request revives an
  IDLE channel (110 ms in the probe; recovery 30 s against 25 s in E4).
  - Option A: when a refusal finds the channel IDLE, wait briefly for READY.
  - Option B: raise the channel's idle timeout so that it does not go IDLE between the breaker's trials.

  Either needs the c1 probe again.

### 12.7 Threats to validity

- **The trace's own cost.** The trace was on for the probes only; the E4 and E3 runs ran without it.
- **Sample size.** E3 is a single run. E4 has three runs. Each probe ran once per step.
- **The 5 s lookup belongs to this host's Docker DNS.** A stopped container's name is forwarded to an upstream
  resolver that times out. Elsewhere it may fail faster or slower; G2 does not depend on it.
- **Bench cadence.** Detection and the start check were measured on the bench, which evaluates every 5 s; live
  evaluates every 15 s.
- **`run.json`'s `git` field** names the main checkouts' commits (§10.7). The `images` ids are the builds named
  above.
