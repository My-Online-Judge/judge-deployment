# Benchmark (sub-project 5)

Load and chaos evaluation of the split system — spec `docs/superpowers/specs/2026-10-05-sp5-load-chaos-evaluation-design.md`.
Everything runs on a separate compose project, `oj-bench`, with its own volumes; the live stack is stopped while
measuring (the container names and networks are fixed, two stacks cannot run together on this host).

## A session

```bash
# 1. stop the live stack — its data stays (no -v)
cd /home/tuan/Project/my-oj/judge-deployment && docker compose down
# 2. a fresh, seeded bench stack (add --history for E1)
bench/env.sh up
# 3. runs — one at a time (run.sh) or a whole family (campaign.sh)
bench/campaign.sh e2-pilots
# 4. remove the bench stack and its volumes, start the live stack again
bench/env.sh down
docker compose up -d
```

## Runs

| command | what |
|---|---|
| `bench/run.sh e1 --rate R` | E1 read latency at R req/s (60 s warm-up, 180 s measured) |
| `bench/run.sh e2 --workers N --steps 1,1.5,2,2.5` | E2 capacity: each step 180 s |
| `bench/run.sh e2 --workers N --pilot` | E2 pilot: 0.5, 1, 1.5, 2 /s per worker, 60 s each; `analyze steps <dir>` prints the measured steps |
| `bench/run.sh e3 --submit-rate X` | E3: 15 min of reads (20/s) + submissions |
| `bench/run.sh e4 --fault c1..c6 --submit-rate X` | E4: 120 s steady, 60 s fault, 180 s recovery |
| `bench/smoke.sh` | a short version of each, with the invariant check |
| `bench/campaign.sh …` | three runs per configuration (see its header) |

Each run writes `results/<time>-<label>/`: `run.json` (versions, image ids, arguments, times), `summary.json` (k6),
`k6.log`, `found.json`, `invariant.json`, `series/*.csv`, `*.png`, `results.json`. Tables over the runs:
`bench/lib/common.sh` → `analyze summarize results e1|e2|e3|e4` writes `results/summary-<exp>.md`.

## Faults (E4)

| | container | how |
|---|---|---|
| c1 | oj-problem-service | stop, start after 60 s |
| c2 | the first judge-worker | crash (`stop --time 0`), start after 60 s |
| c3 | oj-judge-server-2 | stop, start |
| c4 | oj-kafka | stop, start |
| c5 | oj-submission-service | stop, start |
| c6 | oj-redis | stop, start |

`chaos/fault.sh` refuses any container whose compose project is not `oj-bench`.

## Tests

`bench/tests/all.sh` — shell checks (stubs, no stack needed), `node --test` of the k6 helpers, pytest of the data and
the analysis (in the pinned `oj-bench-analyze:1` image).
