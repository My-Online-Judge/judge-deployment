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

## TLS (sub-project 10)

The bench stack is the production compose file, so it needs `pki/out` (`pki/pki.sh init-ca` and `issue-all`; its `tls-init`
fills the project's own `oj-bench_tls` volume). k6 enters through the edge, as a browser does: `BASE` is `https://edge`
(the gateway admits only CN=`edge`, so a direct call from the k6 container is refused), and the k6 containers mount the
`tls-probe` subpath of `oj-bench_tls` and set `SSL_CERT_FILE=/etc/oj/tls/ca.crt` (k6 reads it on Linux; checked against the
pinned image) to trust the private CA. `bench/probe.sh` calls `https://localhost/api/v1` with `curl --cacert
pki/out/ca/ca.crt` (override with `OJ_CA`). Prometheus stays plain HTTP on `127.0.0.1:9090`; the edge's ports 80/443 are
published by the bench stack too, hence the live stack must be down.

## Environment inherited from the live stack

The bench stack reads the same env files as the live one. Two consequences:

- `JUDGE_MAX_QUEUE_DEPTH=200` comes from `.env.submission`, so a bench run admits at most 200 queued submissions. REPORT §13's
  numbers were measured at 500: a run that needs 500 must set it on purpose and say so in its report.
- `.env.identity` now gives access tokens 15 minutes (`JWT_ACCESS_TOKEN_EXPIRATION=900000`, set by `migrations/sp12-env.sh`).
  `bench/k6` logs every user in once in `setup()` (and `check.js` again at the end), so a k6 phase that lasts longer than
  15 minutes after its login meets expired access tokens. Today's runs fit (the longest step is 600 s); keep that limit in mind
  before adding a longer phase.

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

`bench/probe.sh dns|redis` (sub-project 6) shows, request by request, what a stopped problem-service or Redis costs
on a running oj-bench stack, and what each service's log says about it. It stops oj-bench containers only, through
`chaos/fault.sh`.

## Tests

`bench/tests/all.sh` — shell checks (stubs, no stack needed), `node --test` of the k6 helpers, pytest of the data and
the analysis (in the pinned `oj-bench-analyze:1` image).
