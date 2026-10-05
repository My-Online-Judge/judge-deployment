# judge-deployment

**Single source of truth** for running the whole Online Judge system with Docker Compose.
Every service is containerized; all configuration lives in this directory. Build contexts
reference the sibling repos (`../oj-submission-service`, `../oj-identity-service`, `../oj-problem-service`, `../oj-api-gateway`, `../oj-common`, `../judge-portal`,
`../judge-worker`, `../mock-judge-server`) — no source is copied here.

> This directory supersedes the scattered compose files
> (`../docker-compose.integration.yml`, `../docker-compose.mock.yml`,
> `../judge-server/docker-compose.yml`). Those are kept
> as legacy references; prefer this stack.

## Architecture

```
Browser
  ├─ http://localhost        → judge-portal   (nginx:80, static Vue 3 build)
  └─ http://localhost:8000   → api-gateway    (Spring Cloud Gateway: CORS, client-IP boundary)
                                   ├─ /api/v1/{auth,users,roles,permissions,security}/** → identity-service ── identity-db
                                   ├─ /api/v1/problems/** → problem-service ── problem-db, MinIO (test cases)
                                   │                              ↑ gRPC :9090 (GetJudgeSpec, GetSampleTestCases)
                                   ├─ /api/v1/{submissions,languages,judge-servers}/** → submission-service ──┘
                                   └─ any other path → 404 from the gateway
                                                     ├── submission-db (Postgres 16)
                                                     └── kafka  ──produce→ submission.requested, oj.submission.events
                                                                ←consume── submission.judged
                                                                      │            └→ problem-service (statistics)
                                                                judge-worker (Python, kafka-python)
                                                                      │  HTTP POST /judge
                                                                      └→ judge-server ×2 (qduoj sandbox, privileged)
                                                                            └─ heartbeat → submission-service:8000 /api/judge_server_heartbeat/
Traces: api-gateway, submission-service, identity-service, problem-service, judge-worker ──OTLP──→ jaeger (UI http://127.0.0.1:16686)
```

## Services

| Service        | Image / Build            | Host port | Purpose                          |
|----------------|--------------------------|-----------|----------------------------------|
| `kafka`        | `apache/kafka:3.9.0`     | 9092      | Submission event bus (KRaft)     |
| `api-gateway`  | build `../oj-api-gateway`| 8000      | Public API entry (CORS, client IP)|
| `submission-service` | build `../oj-submission-service` | — (internal) | Submissions, judging, languages, judge servers |
| `submission-db` | `postgres:16`           | — (internal) | submission-service's database (`submission`) |
| `identity-service` | build `../oj-identity-service` | — (internal) | Login, users, roles, bans; issues the tokens |
| `identity-db`  | `postgres:16`            | — (internal) | identity-service's database (`identity`) |
| `problem-service` | build `../oj-problem-service` | — (internal) | Problems, test cases, statistics; gRPC API for submission-service |
| `problem-db`   | `postgres:16`            | — (internal) | problem-service's database (`problem`) |
| `jaeger`       | `jaegertracing/jaeger:2.21.0` | 127.0.0.1:16686 | Tracing UI + OTLP collector |
| `judge-worker` | build `../judge-worker`  | —         | Kafka ⇄ judge-server bridge      |
| `judge-server` | `qduoj/judge-server`     | —         | Privileged code sandbox          |
| `judge-portal` | build `../judge-portal`  | 80        | Vue 3 frontend (nginx)           |

## Run

```bash
cd judge-deployment

# real sandbox (default)
docker compose up -d --build

# mock sandbox — offline / CI / no privileged
docker compose -f docker-compose.yml -f docker-compose.mock.yml up -d --build

# logs
docker compose logs -f submission-service judge-worker

# stop (keep Postgres data)
docker compose down

# stop + wipe Postgres volume
docker compose down -v
```

### Endpoints (after `up`)

| What        | URL                              |
|-------------|----------------------------------|
| Portal      | http://localhost                 |
| API         | http://localhost:8000/api/v1     |
| Swagger UI  | http://localhost:8000/swagger-ui/index.html (dev profile only) |
| Jaeger UI   | http://127.0.0.1:16686           |
| Kafka       | kafka:29092 inside oj-net (no host port) |
| Postgres    | identity-db, problem-db, submission-db inside oj-net (no host port) |

## Upgrading to the gateway (sub-project 0)

The api-gateway change spans four repos and must land **together**: the new judge-api image emits
no CORS headers and publishes no host port, so it only works behind `api-gateway`.

1. Clone the new repo beside the others:
   `git clone git@github.com:My-Online-Judge/oj-api-gateway.git ../oj-api-gateway`
   (without it, `docker compose up --build` fails with "path ../oj-api-gateway not found").
2. Pull `main` of `judge-api`, `judge-worker`, `oj-api-gateway` and this repo.
3. Deploy everything in one step: `docker compose up -d --build`.
4. Check: `curl http://localhost:8000/api/v1/languages` → 200 through the gateway, and
   `docker compose ps` shows `oj-api-gateway` and `oj-judge-api` healthy.

Rollback: check out the previous commit of this repo and of `judge-api`, then
`docker compose up -d --build` — judge-api publishes :8000 again and answers CORS itself. No data
changes are involved.

## Self-contained tokens (sub-project 1a)

`oj-common` (shared library) must be cloned beside the other repos; the judge-api and api-gateway
images compile it from there (`additional_contexts`). Deploy judge-api and api-gateway **together**:
judge-api no longer checks bans or revoked tokens — the gateway does, against Redis.
`JWT_SECRET_KEY` is no longer read and can be removed from `.env`.

## Extracting identity-service (sub-project 1b)

identity-service takes over `/api/v1/{auth,users,roles,permissions,security}/**` with its own
database. `oj-identity-service` must be cloned beside the other repos. Its secrets live in
`.env.identity`, read only by `identity-db` and `identity-service`: `.env` keeps no signing key and
no Google secret. The same RSA key pair moves across, so sessions survive the cutover.

Cutover runbook (all from `judge-deployment/`):

1. **Prepare, no traffic yet.** `migrations/split-env-sp1b.sh create` writes `.env.identity`
   (fresh identity-db password + a copy of the JWT and Google settings). Then
   `docker compose up -d --build identity-db identity-service` — Flyway builds the schema
   (V1) and seeds it (V2); the gateway does not route to it yet.
2. **Rehearse.** `migrations/rehearse-sp1-identity.sh` copies a restored dump of `oj-db` into a
   throwaway identity-db twice; every table must report `match`.
3. **Maintenance window.** `docker compose stop api-gateway judge-api`, then
   `migrations/run-sp1-identity.sh` — the eight identity tables are copied in one transaction and
   verified row by row; it exits non-zero on any mismatch.
4. **Switch.** `migrations/split-env-sp1b.sh strip` (removes the moved settings from `.env`;
   backup `.env.pre-sp1b`), then `docker compose up -d --build`: judge-api (Flyway V15 drops the
   `t_submissions → t_users` foreign key) and the gateway with the identity routes.
5. **Smoke test**, then re-open traffic. **Re-opening traffic is the point of no return.** Before
   it, rollback = `cp .env.pre-sp1b .env`, check out the previous commit of this repo, judge-api
   and oj-api-gateway, `docker compose up -d --build --remove-orphans` — the identity tables in `oj-db` were never
   modified. After it, identity-db holds the only up-to-date users. Once you are sure you will not
   roll back, `shred -u .env.pre-sp1b` — the backup still holds the signing key and the Google secret.

## Test cases on MinIO, the outbox (sub-project 2a)

judge-api keeps test-case files in MinIO (`sources/<slug>/<n>.in|out` in the `test-cases` bucket)
instead of on the container's disk, which lost the ones added through the API on every recreate.
Judge requests and verdict events leave judge-api through an outbox table and are sent right after
their commit (alert `OutboxBacklogStale`). Only judge-api changes; rollback = the previous judge-api
image, which runs on the V16/V17 schema unchanged.

Rollout (all from `judge-deployment/`):

1. **Record** the bundles judged today: `migrations/sp2a-bundle-hashes.sh > /tmp/sp2a-before.txt`.
2. **Deploy**: `docker compose up -d --build --no-deps judge-api`. On start, a one-time backfill copies
   every test-case file into MinIO — from the problem's current bundle, else from the copy in the
   jar — and logs `Test-case backfill done: uploaded=… orphans=[…] mismatched=[…] failed=[…]`.
3. **Orphans** are rows whose files exist nowhere; they are not judged today. `migrations/sp2a-orphans.sh`
   lists them; after checking, `migrations/sp2a-orphans.sh delete <id>…` deletes exactly those rows.
   Then `docker compose restart judge-api`.
4. **Verify**: the last backfill line reads `orphans=[] mismatched=[] failed=[]`, and
   `migrations/sp2a-bundle-hashes.sh | diff /tmp/sp2a-before.txt -` prints nothing: every problem is
   judged against exactly the bundle it was before.

## Extracting problem-service (sub-project 2b)

problem-service takes over `/api/v1/problems/**` with its own database; judge-api asks it for each
submission's limits and test-case version over gRPC (`problem-service:9090`, service token
`PROBLEM_RPC_TOKEN`), behind a circuit breaker: while it is away submissions get 503 (alerts
`ProblemServiceDown`, `ProblemServiceCircuitOpen`). Statistics move into problem-db and are kept from
`oj.submission.events`. `oj-problem-service` must be cloned beside the other repos. MinIO is shared: the
test-case files written in 2a stay where they are.

Cutover runbook (all from `judge-deployment/`):

1. **Prepare, no traffic yet.** `migrations/sp2-env.sh` writes `.env.problem` (problem-db credentials,
   generated password) and adds `PROBLEM_RPC_TOKEN` to `.env`. **Keep the running images for a rollback**
   — once oj-common is 0.2.0 the 2a images cannot be rebuilt (their poms require oj-common 0.1.0):
   `for s in judge-api api-gateway; do docker tag judge-deployment-$s:latest judge-deployment-$s:pre-sp2b; done`.
   Then build every image: `docker compose build problem-service judge-api api-gateway`, and
   `docker compose up -d problem-db problem-service` — Flyway builds the schema (V1 the problem tables, V2
   statistics) — and `docker compose stop problem-service`, so its statistics consumer is not running
   during the copy.
2. **Rehearse.** `migrations/rehearse-sp2-problem.sh` copies a restored dump of `oj-db` into a throwaway
   problem-db twice, checks that two tampered values make the verification fail and that a problem-db
   that has moved on makes a new copy refuse; it ends with `REHEARSAL OK`.
3. **Maintenance window.** `docker compose stop api-gateway` (no new submissions), then wait until no
   submission is waiting for its verdict —
   `docker exec oj-db psql -U "$DATABASE_USERNAME" -d "$DATABASE_NAME" -tAc "SELECT count(*) FROM t_submissions WHERE status IN (6, 7)"`
   prints `0` (values from `.env`). Otherwise a window longer than `JUDGE_STUCK_TIMEOUT_MIN` (5 minutes)
   lets judge-api's reconcile job mark them SYSTEM_ERROR before their verdicts are read back. Then
   `docker compose stop judge-api` and `migrations/run-sp2-problem.sh` — the problem tables are copied and
   the statistics seeded from the terminal submissions in one transaction, then verified; it exits
   non-zero on any mismatch.
4. **Switch.** `docker compose up -d problem-service judge-api api-gateway`: judge-api (Flyway V18 makes
   `t_submissions.problem_slug` required) and the gateway with the problem routes.
5. **Smoke test** without changing any problem: the list and a problem page load, a submission is
   judged and its problem's accepted count goes up.
6. **Re-open traffic: the point of no return.** Before it, rollback = put the kept images back
   (`for s in judge-api api-gateway; do docker tag judge-deployment-$s:pre-sp2b judge-deployment-$s:latest; done`),
   check out the previous commit of this repo, and `docker compose up -d --no-build --remove-orphans`.
   The problem tables in `oj-db` were never modified; problem-db and its volume stay aside, unused;
   identity-service is not rebuilt in this runbook, so it keeps running as it was. The 2a judge-api runs
   on the V18 schema (it always writes `problem_slug`; Flyway ignores a migration newer than the image).
   After it, problem-db holds the only up-to-date problems — never run `migrations/run-sp2-problem.sh`
   again: oj-db's problem tables are stale from then on, and the copy refuses once problem-db holds
   anything oj-db does not (`FORCE=1` would replace it with the stale data).
7. **Smoke test the writes**: create a problem, delete it, create it again with the same slug — rejected.

## Renaming judge-api to submission-service (sub-project 3a)

What is left of the monolith is the submission side, and 3a gives it that name everywhere it runs: compose
service and container `submission-service`, its OpenTelemetry and Prometheus names (alert
`SubmissionServiceDown`), the sandboxes' `BACKEND_URL`. Its code still builds from `../judge-api` until 3b
moves it to `oj-submission-service`; the Kafka consumer group stays `judge-api-results`. The gateway now
routes `/api/v1/{submissions,languages,judge-servers}/**` to it explicitly (`SUBMISSION_URI`) and answers any
unclaimed `/api/v1/**` path with its own 404. All Java services share oj-common 0.3.0's error responses.
The runbooks above name the service `judge-api`, its name at the time.

Rollout (all from `judge-deployment/`):

1. **Record** the error responses: `PROBE_USERNAME=… PROBE_PASSWORD=… migrations/sp3a-error-responses.sh >
   /tmp/sp3a-before.txt` (an existing USER account; the script prints no credentials).
2. **Keep** the running images for a rollback:
   `for s in judge-api api-gateway identity-service problem-service; do docker tag judge-deployment-$s:latest judge-deployment-$s:pre-sp3a; done`.
3. **Rename** the service in your local `docker-compose.override.yml` too (`judge-api:` → `submission-service:`),
   then `docker compose up -d --build --remove-orphans submission-service identity-service problem-service
   api-gateway judge-server judge-server-2 prometheus` — `oj-judge-api` is removed, `oj-submission-service`
   takes its place; submissions pause for those seconds.
4. **Compare**: `migrations/sp3a-error-responses.sh | diff /tmp/sp3a-before.txt -` shows only the unclaimed
   path, now `404` from the gateway instead of `401` from judge-api (the language list differs too if a language
   was edited in between).
5. **Rollback**: re-tag the `:pre-sp3a` images to `:latest` under their old names (`judge-api` for
   submission-service), check out the previous commit of this repo, rename `submission-service:` back to
   `judge-api:` in your `docker-compose.override.yml` (Compose refuses an override entry for a service the file
   does not define), then `docker compose up -d --no-build --remove-orphans`.

## Extracting submission-service (sub-project 3b)

submission-service moves to its own repo, `oj-submission-service` (judge-api's history carried over), and its own
database, `submission-db`; oj-db is then retired. `oj-submission-service` must be cloned beside the other repos.
Its secrets live in `.env.submission`, read only by `submission-db` and `submission-service`, which no longer reads
the shared `.env`. The gateway and the sandboxes need no change: they have called it `submission-service` since 3a.

**Never start the new submission-service before the copy**: it would join Kafka consumer group
`judge-api-results` next to the running one and take verdicts for submissions it does not have. Its schema is
built by `migrations/sp3-flyway.sh`, a one-shot Flyway container on the service's own migrations.

Cutover runbook (all from `judge-deployment/`):

1. **Prepare, no traffic yet.** `migrations/sp3-env.sh create` writes `.env.submission` (generated password).
   Keep the running image for a rollback:
   `docker tag judge-deployment-submission-service:latest judge-deployment-submission-service:pre-sp3b`.
   Build: `docker compose build submission-service`. Then `docker compose up -d --no-deps submission-db` and
   `migrations/sp3-flyway.sh` (V1 the submission tables, V2 the languages). **From here until step 4, never run a
   bare `docker compose up -d`** (nor `up -d` of a service that depends on submission-service, such as
   `prometheus` or `api-gateway`): it would recreate submission-service as the new one, started early. Name the
   service and pass `--no-deps`.
2. **Rehearse.** `migrations/rehearse-sp3-submission.sh` copies a restored dump of oj-db into a throwaway
   submission-db twice, checks that two tampered values make the verification fail and that a submission-db that
   has moved on makes a new copy refuse; it ends with `REHEARSAL OK`.
3. **Maintenance window.** `docker compose stop api-gateway`. Note how many submissions already ended in
   SYSTEM_ERROR —
   `docker exec oj-db psql -U "$DATABASE_USERNAME" -d "$DATABASE_NAME" -tAc "SELECT count(*) FROM t_submissions WHERE status = 5"`
   (values from `.env`) — then wait until nothing is in flight: the same command with
   `SELECT count(*) FROM t_submissions WHERE status IN (6, 7)` and with
   `SELECT count(*) FROM t_outbox WHERE published_at IS NULL` both print `0`. Then
   `docker compose stop submission-service` (the consumer group commits its offsets) and
   `migrations/run-sp3-submission.sh` — the four tables, every outbox row included, are copied in one transaction
   and verified; it exits non-zero on any mismatch.
4. **Switch.** `docker compose up -d submission-service prometheus api-gateway`: the new service resumes
   `judge-api-results` from the committed offsets; Prometheus scrapes it on 8081. Check the group:
   `docker exec oj-kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group judge-api-results`
   lists every partition with a consumer and `LAG` 0.
5. **Smoke test**: log in, submit; the verdict arrives over SSE through the gateway; the problem's accepted count
   goes up; old submission histories list completely. In Jaeger (<http://localhost:16686>, service `api-gateway`)
   the submission's trace spans api-gateway, submission-service, problem-service and judge-worker. Nothing was
   flipped to SYSTEM_ERROR by the window:
   `docker exec oj-submission-db psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAc "SELECT count(*) FROM t_submissions WHERE status = 5"`
   (values from `.env.submission`) prints the number noted in step 3, and the consumer group's `LAG` is back to 0.
6. **Re-open traffic: the point of no return.** Before it, rollback =
   `docker tag judge-deployment-submission-service:pre-sp3b judge-deployment-submission-service:latest`, check out
   the previous commit of this repo, `docker compose up -d --no-build --remove-orphans` (oj-db untouched; only the
   smoke submission is lost). After it, submission-db holds the only up-to-date submissions — never run
   `migrations/run-sp3-submission.sh` again (it refuses once submission-db holds anything oj-db does not;
   `FORCE=1` would replace it with stale data).
7. **Retire oj-db**: see "Retiring oj-db" below. Steps 1–6 run with the compose file of the commit that adds
   submission-db (oj-db still defined); the retirement moves to the next commit.

## Retiring oj-db (sub-project 3b, after the point of no return)

Nothing reads oj-db once submission-service runs on submission-db. Retire it in this order:

1. **Back it up**: `migrations/sp3-backup-oj-db.sh` writes `backups/oj-db-final-<date>.dump` (owner-only; it
   also holds the stale identity tables' password hashes, so it is gitignored and never pushed) and checks that
   `pg_restore --list` reads it back.
2. **Check out this commit** (the compose file without the `db` service), drop the `db:` entry from your local
   `docker-compose.override.yml` (Compose refuses an override for a service the file no longer defines), then
   `docker compose up -d --remove-orphans` — `oj-db` is stopped and removed.
3. **Strip** its credentials from `.env`: `migrations/sp3-env.sh strip` (backup `.env.pre-sp3b`, owner-only;
   `shred -u` it once you are sure).
4. The volume `judge-deployment_pgdata` is kept. Deleting it is irreversible and up to you:
   `docker volume rm judge-deployment_pgdata`.
5. **Archive** the judge-api repository on GitHub; its history lives on in `oj-submission-service`.

## Configuration

Shared knobs live in **`.env`**. No service loads it through `env_file`: each gets only the variables it
needs through `${VAR}` interpolation, and its database settings from its own file (`.env.identity`,
`.env.problem`, `.env.submission`).
Copy `.env.example` → `.env` to start from a clean template.

Notes:
- `api-gateway` does **not** load `.env`; compose passes it only the service URIs, the profile and
  the OpenTelemetry settings. submission-service is not published on the host — everything goes
  through the gateway on :8000.
- `.env` holds **container-network** addresses (`kafka:29092`, `judge-server`).
- `.env` and every `.env.<service>` hold secrets: keep them mode 600 (`chmod 600 .env`).
- One `JUDGE_SERVER_TOKEN` is shared by api, worker, and judge-server.
- `problem-service` does not load `.env` either: it reads `.env.problem` (its database) and compose
  passes it MinIO, Kafka, the JWKS URI and `PROBLEM_RPC_TOKEN`; submission-service likewise reads
  `.env.submission` plus Kafka, Redis, the judge-server token and `PROBLEM_RPC_TOKEN`.
- `submission-service` runs the profile in `.env.submission` (the image's default is **dev**, baked in via
  `pom.xml`); both serve the API on **8000** and actuator on **8081**.
- `GOOGLE_REDIRECT_URI` must match the Google console. It points at the Vite dev origin
  (`:5173`); if you drive OAuth through the containerized portal (`http://localhost`), update
  both the `.env` value and the console.

## Host notes (this machine)

The compose files are daemon-agnostic, but on this host there are two Docker daemons and
some local quirks worth recording:

- **Runs on the snap Docker daemon (`default` context), not Docker Desktop.** Docker
  Desktop's VM breaks Alpine/**musl** images — `apache/kafka:3.9.0`'s `/bin/bash` throws
  `Error relocating … symbol not found` and the container exits 127. The identical image
  (same digest) runs fine on the snap daemon. So manage this stack with the `default`
  context:
  ```bash
  docker --context default compose up -d --build
  docker --context default compose ps
  # or make it the default: docker context use default
  ```
- **Kafka host port `9092` is intentionally not published** (see the commented block in
  `docker-compose.yml`) because a legacy `kafka` container already owns host `9092`. All
  services use the in-network `kafka:29092` listener, so nothing is lost. Re-enable the
  publish once host `9092` is free.
- **`oj-judge-server` shows `unhealthy` — this is cosmetic.** The `qduoj/judge-server`
  image's built-in healthcheck (`python3 /code/service.py`) exits 1 on this setup (the
  legacy judge-server behaves identically). The server is functional: it heartbeats to
  `submission-service:8000` and registers in `t_judge_servers`. Nothing depends on its health
  (`judge-worker` waits on `service_started`).
- **Legacy stacks may still be running** on the snap daemon (`judge-server` and `my-oj`
  compose projects — the scattered files this directory replaces). They coexist with this
  stack but are redundant; stop them when convenient (their privileged containers may need
  elevated privileges to stop).
