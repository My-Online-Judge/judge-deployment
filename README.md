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
  └─ https://localhost  (80 → 308 to https)  → edge (Caddy, private-CA certificate; the only public listener)
        ├─ /api/*  → api-gateway   (Spring Cloud Gateway: CORS, client-IP boundary; accepts only CN=edge)
        └─ the rest → judge-portal (nginx, static Vue 3 build; accepts only CN=edge)
                                   ├─ /api/v1/{auth,users,roles,permissions,security}/** → identity-service ── identity-db
                                   ├─ /api/v1/problems/** → problem-service ── problem-db, MinIO (test cases)
                                   │                              ↑ gRPC :9090 (GetJudgeSpec, GetSampleTestCases)
                                   ├─ /api/v1/{submissions,languages,judge-servers}/** → submission-service ──┘
                                   └─ any other path → 404 from the gateway
                                                     ├── submission-db (Postgres 16)
                                                     └── kafka  ──produce→ submission.requested, oj.submission.events
                                                                ←consume── submission.judged
                                                                      │            └→ problem-service (statistics)
                                                                judge-worker (Python, kafka-python) ── relays each sandbox's /ping
                                                                      │  HTTP POST /judge                → submission-service:8000
                                                                      │  (sandbox-net: internal, worker + sandboxes only)   /api/judge_server_heartbeat/
                                                                      └→ judge-server ×2 (qduoj sandbox: no privileged, 6 caps, read-only)
Traces: api-gateway, submission-service, identity-service, problem-service, judge-worker ──OTLP, mutual TLS──→ jaeger (UI http://127.0.0.1:16686)
```

## Services

| Service        | Image / Build            | Host port | Purpose                          |
|----------------|--------------------------|-----------|----------------------------------|
| `kafka`        | `apache/kafka:3.8.1`     | — (internal) | Submission event bus (KRaft), heap `-Xmx512M -Xms512M`, `mem_limit` 1g: `kafka:29092` TLS + client certificate; `127.0.0.1:9092` PLAINTEXT only inside the container |
| `edge`         | `caddy:2.11.7-alpine`    | 80, 443   | The one public listener: HTTPS with the private-CA certificate, `/api/*` to the gateway, the rest to the portal, both over mutual TLS (`edge/Caddyfile`) |
| `api-gateway`  | build `../oj-api-gateway`| — (internal) | API entry behind the edge (CORS, client IP from the edge's `X-Forwarded-For`); answers only CN=`edge`; calls the services over mutual TLS; actuator `:8081` TLS + client certificate |
| `submission-service` | build `../oj-submission-service` | — (internal) | Submissions, judging, languages, judge servers; API `:8000` and actuator `:8081` TLS + client certificate (API callers allow-listed by CN) |
| `submission-db` | `postgres:16`           | — (internal) | submission-service's database (`submission`) |
| `identity-service` | build `../oj-identity-service` | — (internal) | Login, users, roles, bans; issues the tokens; API `:8000` and actuator `:8081` TLS + client certificate (API callers allow-listed by CN) |
| `identity-db`  | `postgres:16`            | — (internal) | identity-service's database (`identity`) |
| `problem-service` | build `../oj-problem-service` | — (internal) | Problems, test cases, statistics; gRPC API for submission-service; API `:8000` and actuator `:8081` TLS + client certificate (API callers allow-listed by CN) |
| `problem-db`   | `postgres:16`            | — (internal) | problem-service's database (`problem`) |
| `jaeger`       | `jaegertracing/jaeger:2.21.0` | 127.0.0.1:16686 | Tracing UI (plain HTTP, loopback only) + OTLP collector (`jaeger/config.yaml`): `:4317`/`:4318` TLS + client certificate, in-memory, at most 100000 traces |
| `judge-worker` | build `../judge-worker`  | —         | Kafka ⇄ judge-server bridge; relays sandbox status to the registry (mutual TLS); `/metrics` `:9100` TLS + client certificate |
| `judge-server` | `docker.io/qduoj/judge-server@sha256:a580a164…` (2020-07-09, pinned) | — | Code sandbox (×2) on the internal `sandbox-net`; least privilege, see `x-sandbox`; API `:8080` TLS + client certificate (the worker's) |
| `judge-portal` | build `../judge-portal`  | — (internal) | Vue 3 frontend (nginx, TLS, answers only CN=`edge`) |
| `alertmanager` | see [Alerting](#alerting-sub-project-12) | 9093 (loopback) | Receives Prometheus's alerts; Telegram when configured |
| `grafana` | see [Dashboards](#dashboards-sub-project-12) | 3000 (loopback) | Provisioned dashboards over Prometheus |
| `node-exporter`, `cadvisor`, `{identity,problem,submission}-db-exporter`, `redis-exporter`, `kafka-exporter` | see [Observability](#observability-sub-project-12) | — (internal) | Metrics for Prometheus: the host, every container, the three databases, Redis and Kafka |

## Run

```bash
cd judge-deployment

# refuse to build from sibling repos that are off main or dirty (exit 1 on FAIL)
scripts/preflight.sh   # from a git worktree, set OJ_ROOT to the directory holding the sibling repos

# real sandbox (default): build one image at a time on this host (see Images), then start without building
for svc in identity-service problem-service submission-service api-gateway judge-worker judge-portal; do
  docker compose build "$svc"
done
docker compose up -d --no-build

# mock sandbox — offline / CI: the same builds, plus the mock sandbox's image, then start without building
docker compose -f docker-compose.yml -f docker-compose.mock.yml build judge-server
docker compose -f docker-compose.yml -f docker-compose.mock.yml up -d --no-build

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
| Portal      | https://localhost (`OJ_PUBLIC_HOST`; http:// answers 308 to it) |
| API         | https://localhost/api/v1         |
| Swagger UI  | not published (the gateway has no host port; dev profile only) |
| Jaeger UI   | http://127.0.0.1:16686 (plain HTTP, loopback only) |
| Prometheus  | http://127.0.0.1:9090 (loopback only; scrapes the actuators over mutual TLS) |
| Alertmanager | http://127.0.0.1:9093 (plain HTTP, loopback only; alerts and silences) |
| MinIO       | https://127.0.0.1:9000 (API), https://127.0.0.1:9001 (console); loopback only |
| Kafka       | kafka:29092 inside oj-net (no host port) |
| Postgres    | identity-db, problem-db, submission-db inside oj-net (no host port) |

Clients trust the private CA: `curl --cacert pki/out/ca/ca.crt https://localhost/api/v1/languages`. Browsers need
`pki/out/ca/ca.crt` imported once (or accept the warning for local use).

## Run it on one machine (a laptop)

`scripts/local-stack.sh` starts the stack with the mock sandboxes on a laptop with Docker Desktop. Needs the sibling repos
beside this one (see `scripts/preflight.sh`), `python3`, `openssl`, `curl`, and on macOS Homebrew's bash (`brew install bash`;
the script runs itself under it).

```bash
scripts/local-stack.sh doctor   # what is missing; changes nothing
scripts/local-stack.sh init     # .env* files with random secrets, the private CA and every certificate (keeps what exists)
scripts/local-stack.sh build    # the images, one at a time (the first build downloads the Maven dependencies)
scripts/local-stack.sh up       # start and wait until healthy
scripts/local-stack.sh smoke    # log in, create a problem, submit, run: the stack answers end to end
scripts/local-stack.sh status   # containers and their memory (Kafka is capped at 1g, heap 512M)
scripts/local-stack.sh down [--volumes]   # stop; --volumes also deletes the databases and every upload
```

Then `https://localhost` is the portal and the API. Trust `pki/out/ca/ca.crt` in the browser (or accept the warning); the root
admin is `admin` with the password the identity V2 migration seeds, `Admin@12345` (change it, then put it in `.env` as
`OJ_ADMIN_PASSWORD` for `smoke`).

What is different from the server stack:

- **Mock sandboxes** (`docker-compose.mock.yml`): the real qduoj image is amd64 and needs the host's kernel for its judger.
  The mock answers like the real server where the worker can tell (one result per case of the bundle, `/ping`), and a
  `TRIGGER_WA`, `TRIGGER_TLE`, `TRIGGER_MLE`, `TRIGGER_RE`, `TRIGGER_SE` or `TRIGGER_CE` comment in the source picks the verdict.
- **No observability**: Prometheus, Grafana, Alertmanager, cAdvisor and the exporters read the Linux host (`/proc`, `/sys`,
  `docker.sock`) and are left out.
- **MinIO's console** (`127.0.0.1:9001`) is not published (`docker-compose.local.yml`); `doctor` and `up` stop when a port
  the stack needs is held by another container or process, and name it.
- **On an Apple-silicon Mac** the Java images' runtime stage, `eclipse-temurin:17-jre-alpine`, has no arm64 variant, so `build`
  swaps it for an alpine JRE 17 that has one (`LOCAL_JRE_IMAGE`, default `bellsoft/liberica-openjre-alpine:17`) with
  `docker buildx --build-context`. The Dockerfiles are untouched; the result is good for trying the stack, not a release image.
- `build` refuses when a service's pom pins an `oj-common` version other than the sibling checkout's: each Dockerfile compiles
  the checkout, so the image could not be built.
- `smoke` leaves its problem (`smoke-a-plus-b`) and submissions in the local database.

## TLS everywhere (sub-project 10)

Every hop is mutual TLS with certificates from the private CA in `pki/` (`pki/README.md`); the services admit callers by
certificate CN (`oj.tls.allowed-clients`), not by shared tokens. Only the edge is public.

### Deploy order (from `judge-deployment/`, once, before the first `up`)

1. If the site is not `localhost`, set `OJ_PUBLIC_HOST=<host>` in `.env` **first**: the edge certificate's SAN and the
   identity URLs below are built from it.
2. `pki/pki.sh init-ca` (once; refuses to overwrite) then `pki/pki.sh issue-all` (every leaf; the edge leaf names
   `OJ_PUBLIC_HOST`). `pki/pki.sh status` lists id, days left and serial.
3. `migrations/sp10-env.sh create`: backs up each `.env*` to `<file>.pre-sp10`, writes `.env.identity-db` (identity-db no
   longer receives the JWT and Google secrets), one MinIO account per service, a 48-character `JUDGE_SERVER_TOKEN`, drops
   the keys compose no longer reads (`PROBLEM_RPC_TOKEN`, `MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `MINIO_ENDPOINT`,
   `JUDGE_SERVER_URL`) and moves `APP_BASE_URL` / `GOOGLE_REDIRECT_URI` to `https://<OJ_PUBLIC_HOST>`. It prints names only.
4. Register the new redirect URI (`https://<OJ_PUBLIC_HOST>/api/v1/auth/outbound/google/callback`) in the Google console.
5. `docker compose up -d --build`: `tls-init` copies the certificates into the `tls` volume, then everything starts.
6. Import `pki/out/ca/ca.crt` into the browser or OS trust store, open `https://<OJ_PUBLIC_HOST>`.
7. Verify with `bash tests/tls.test.sh` (the matrix: wrong or missing client certificates must be refused on every hop).

### Rotation

Leaves live 365 days (alert `TlsCertificateExpiringSoon` names the service 30 days ahead). Re-issue with the same CA:
`pki/pki.sh issue-all`, then `docker compose up -d --force-recreate tls-init`, then restart the services
(`docker compose restart`): a subpath mount keeps the old directory until the container restarts. One service only:
`pki/pki.sh issue <id>`, re-run `tls-init`, `docker compose restart <id>`.

### The CA key is backed up

`pki/out/` holds the only copy of the CA key. `backup/backup.sh` includes `pki/out` in the nightly restic snapshot
(with the `.env*` files; `restore-drill.sh` checks the databases only, so restore `pki/out` from the snapshot by hand). Losing the CA means re-issuing everything and
re-importing the CA in every browser. A leaked CA key: `pki/pki.sh init-ca --force`, `issue-all`, redo the rotation.

### Rollback

`migrations/sp10-env.sh restore` puts the `.env*` files back from `<file>.pre-sp10`; then check out the previous commits of
this repo and of each service and `docker compose up -d --build --remove-orphans`. No data migration is involved; the
`tls` volume and `pki/out` can stay.

## Upgrading to the gateway (sub-project 0)

The api-gateway change spans four repos and must land **together**: the new judge-api image emits
no CORS headers and publishes no host port, so it only works behind `api-gateway`.

1. Clone the new repo beside the others:
   `git clone git@github.com:My-Online-Judge/oj-api-gateway.git ../oj-api-gateway`
   (without it, `docker compose up --build` fails with "path ../oj-api-gateway not found").
2. Pull `main` of `judge-api`, `judge-worker`, `oj-api-gateway` and this repo.
3. Deploy everything in one step: `docker compose up -d --build`.
4. Check: `curl --cacert pki/out/ca/ca.crt https://localhost/api/v1/languages` (from sub-project 10 on; originally `http://localhost:8000/...`) → 200 through the gateway, and
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
   prints `0` (values from `.env`). Otherwise a window longer than `JUDGE_JUDGING_TIMEOUT` (3 minutes; a
   PENDING row waits `JUDGE_PENDING_TIMEOUT`, 30 minutes) lets judge-api's reconcile job mark them SYSTEM_ERROR
   before their verdicts are read back. Then
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

Cutover runbook (all from `judge-deployment/`). Historical: its `docker tag judge-deployment-submission-service:latest|pre-sp3b`
commands use the image names from before sub-project 12, which now names images `ghcr.io/my-online-judge/…` (see
[Images](#images-sub-project-12)).

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
   `docker exec oj-kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 --describe --group judge-api-results`
   lists every partition with a consumer and `LAG` 0.
5. **Smoke test**: log in, submit; the verdict arrives over SSE through the gateway; the problem's accepted count
   goes up; old submission histories list completely. In Jaeger (<http://127.0.0.1:16686>, service `api-gateway`)
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
4. **Delete** its volume once the backup reads back; the compose file no longer declares it, and this is
   irreversible: `docker volume rm judge-deployment_pgdata`.
5. **Archive** the judge-api repository on GitHub; its history lives on in `oj-submission-service`.

## Benchmarking (sub-project 5)

`bench/` holds the load and chaos harness: a separate `oj-bench` compose project, k6 scenarios, faults, and the
analysis that turns each run into CSV, charts and tables. The live stack is stopped while it runs. See
[bench/README.md](bench/README.md).

## Images (sub-project 12)

Every built service names its image `${OJ_REGISTRY:-ghcr.io/my-online-judge}/<name>:<tag>` in `docker-compose.yml`
(`oj-identity-service`, `oj-problem-service`, `oj-submission-service`, `oj-api-gateway`, `judge-worker`, `judge-portal`),
with the tag `OJ_<NAME>_TAG`, else `OJ_TAG`, else `main` (`.env.example` lists the variables). Each service keeps its
`build:`, so `docker compose build <service>` tags the local build with that name and `docker compose up -d --no-build`
runs it without pulling. Build one image at a time on this host. The bench overlay runs the same names, never pulled.

Compose v5 pulls first for a service with both `image:` and `build:`, and builds only when the pull fails. So once CI has
pushed a readable `:main`, a bare `docker compose up` on a host without the local tag runs CI's image instead of building
from the sibling checkouts. Pick the path explicitly. For a local build, run `docker compose build <service>` (one at a
time on this host), then `docker compose up -d --no-build`. For CI's images, run `docker compose pull`, then
`docker compose up -d --no-build`.

- **Rollback** to an earlier image: `OJ_<NAME>_TAG=<old sha> docker compose up -d <service>`, or for every service tagged
  alike `OJ_TAG=<shared tag> docker compose up -d`.
- **Logs** of every container rotate: json-file, 3 files of 10 MB (`x-logging`).
- **The sandbox** is pinned by digest at its source: `docker.io/qduoj/judge-server@sha256:a580a164...` (the 2020-07-09
  image). The first `up` after this change pulls it (2.25 GB).
- **Optional: mirror the sandbox into the org's GHCR** so a Docker Hub outage cannot stop a deploy. It needs a GitHub token
  with `write:packages`; run it yourself, then point `x-sandbox.image` at the mirror:

  ```bash
  gh auth token | docker --context default login ghcr.io -u <github user> --password-stdin
  docker --context default buildx imagetools create --tag ghcr.io/my-online-judge/judge-server:qduoj-2020-07-09 \
    docker.io/qduoj/judge-server@sha256:a580a1643277b4ec5a103a46fe1dbfe8537c437996955f82a5a22801ec73239e
  docker --context default buildx imagetools inspect ghcr.io/my-online-judge/judge-server:qduoj-2020-07-09
  ```

  If the mirror's digest differs from `a580a164...` (it became an index), pin the mirror's own digest.

## Non-root containers (sub-project 12)

The four Java services, the worker and the portal run as uid 10001 (portal: nginx, uid 101). `pki/identities.txt` gives
each the matching owner, so `tls-init` chowns its certificate directory (0700) and key (0600) to it. `volume-init` chowns
the `test_case_cache` volume to 10001 before the worker starts. The portal binds 443 as uid 101 because Docker sets
`net.ipv4.ip_unprivileged_port_start=0` in a container (Docker 20.10 or newer, bridge networking). On a host where it is
not, switch to `listen 8443 ssl` in `portal/nginx-tls.conf`, `reverse_proxy https://judge-portal:8443` in
`edge/Caddyfile`, and `judge-portal:8443` in `tests/tls.test.sh`. `cap_add: NET_BIND_SERVICE` is no fallback.

`scripts/nonroot-audit.sh [project]` lists any root process in a running project (`ROOT <service> <comm>`, exit 1; else
`PASS`). Allowed to be root by default: the sandboxes, edge, minio, cadvisor and node-exporter (`NONROOT_ALLOW`).

## Observability (sub-project 12)

Prometheus (`http://127.0.0.1:9090`) scrapes, besides the services' actuators and the workers, one exporter per thing
it watches, each in its own job named after the service (`prometheus.yml`):

| Service | Image | Port | What it exports |
|---|---|---|---|
| `node-exporter` | `prom/node-exporter:v1.12.1` | 9100 | The host: CPU, memory, filesystems (host pid namespace, read-only `/proc`, `/sys`, `/`) |
| `cadvisor` | `ghcr.io/google/cadvisor:v0.60.6` | 8080 | CPU and memory of every container, labelled with its name |
| `identity-db-exporter`, `problem-db-exporter`, `submission-db-exporter` | `prometheuscommunity/postgres-exporter:v0.20.1` | 9187 | Each database, as the read-only role `oj_monitor` |
| `redis-exporter` | `oliver006/redis_exporter:v1.96.0` | 9121 | Redis |
| `kafka-exporter` | `danielqsj/kafka-exporter:v1.11.0` | 9308 | Topic offsets and consumer-group lag |

- **Mutual TLS, like every hop (sub-project 10).** Six exporters serve `/metrics` with the leaf of their own tls subpath
  and require a client certificate signed by the CA; Prometheus presents its own. node-exporter and the
  postgres-exporters read the compose config `exporter-web`, redis-exporter its `-tls-server-*` flags, kafka-exporter its
  `--server.tls.*` flags. Each runs as its image's own user, the owner `pki/identities.txt` gives its identity. None
  publishes a port. `bash tests/tls.test.sh` (section `exporters`) checks that no certificate and a foreign one are refused.
- **cAdvisor is plain HTTP** inside oj-net: it has no TLS (a documented exception, like the loopback operator UIs). It
  runs as root, not privileged, with read-only `docker.sock` and `containerd.sock`: this host's Docker keeps images in the
  containerd snapshotter, which v0.52.1 could not follow (no container was registered); v0.60.6 reads them through
  containerd. It collects only CPU and memory: the disk metrics filled about 200 MiB of kernel dentry cache charged to
  its 256 MiB cap.
- **The exporters' own connections are TLS with client certificates too.** The postgres-exporters use `verify-full`, plus
  scram as `oj_monitor`, whose password is `PG_MONITOR_PASSWORD` in `.env`. redis-exporter uses `rediss://redis:6379`.
  kafka-exporter uses `kafka:29092` as CN `kafka-exporter`, which `kafka/acls.sh` allows to describe every topic and group
  and the cluster, and nothing else.
- **Memory caps** (`mem_limit`): cadvisor 256 MiB, each of the others 64 MiB. On 2026-10-20 each used at most a third of
  its cap.
- **Bench:** the exporters are in profile `off` there (`bench/compose.bench.yml`), and the bench Prometheus reports their
  targets down.

Deploying them, once, from `judge-deployment/`:

1. `PG_MONITOR_PASSWORD` must be in `.env` (`migrations/sp12-env.sh create` generates it). Compose refuses to start
   without it.
2. `pki/pki.sh issue <id>` for each new identity: `node-exporter`, the three `*-db-exporter`, `redis-exporter` and
   `kafka-exporter`. Not `issue-all`, which re-issues every leaf (a rotation, see above).
3. `migrations/sp12-pg-monitor.sh` creates `oj_monitor` in the three running databases (`docker exec` over the Unix
   socket, password through stdin) and prints `ok <container>` for each. It is idempotent: run it again after the
   password changes.
4. `docker compose up -d --no-build`: `tls-init` installs the new leaves and `kafka-init` adds kafka-exporter's ACLs.
   Then check that every exporter target is up at `http://127.0.0.1:9090/targets`.

## Alerting (sub-project 12)

Prometheus evaluates `alerts.yml` and sends every firing alert to `alertmanager` (`prometheus.yml`, `alerting:`).
Alertmanager (`prom/alertmanager:v0.34.1`, `mem_limit` 64 MiB) groups them by `alertname`, waits 30 s, and repeats a
still-firing alert every 4 h.

- **UI and silences:** `http://127.0.0.1:9093` (plain HTTP, loopback only, like the other operator UIs). Silence an alert
  under *Silences*, or from an alert's *Silence* button; silences live in the `alertmanagerdata` volume.
- **Telegram, when configured.** Put both in `.env`, then `docker compose up -d alertmanager`:
  `ALERT_TELEGRAM_BOT_TOKEN` (from @BotFather) and `ALERT_TELEGRAM_CHAT_ID` (an integer; a group's starts with `-`;
  the bot must be a member). With either unset, alerts only show in the UI. `alertmanager/render.sh` renders the config
  at container start and prints only `alertmanager receiver: telegram` or `ui-only`; the token goes to a 0600 file in
  the container's `/tmp`, so it is not in `docker compose config` output beyond the environment passthrough. Each
  message is `[FIRING] <alertname> (<severity>): <summary>` (`alertmanager/telegram.tmpl`); resolved alerts are sent too.
- **Run lane:** `RunWorkerDown` (warning) fires when no `run-worker` replica answers its scrape for 15 s — Run answers
  504 meanwhile, Submit is unaffected (see "Run lane (custom test cases)").
- **Outbox:** `OutboxBacklogStale` (critical) means rows are not reaching Kafka; `OutboxDeadRow` (warning) means the relay gave
  up on a row the broker refused for good (too large, not authorised) five times, so it is never sent again. The relay sends
  outside a database transaction and a lease (`claimed_until`, 60 s) keeps two instances from sending one row. Look at the dead
  rows in submission-db: `SELECT id, topic, message_key, attempts, dead_at FROM t_outbox WHERE dead_at IS NOT NULL`. After
  fixing the cause (an ACL in `kafka/acls.sh`, a topic's `max.message.bytes`), put a row back with
  `UPDATE t_outbox SET attempts = 0, dead_at = NULL, claimed_until = NULL WHERE id = '<id>'`, or delete it when its work is
  moot (a submission whose request is lost is failed by reconcile as `Judging request lost` and can be rejudged).
- **Bench:** `alertmanager` is in profile `off` there; the bench Prometheus logs one failed notification per alert.
- Check: `bash tests/alertmanager.test.sh` (amtool in the pinned image, with and without the variables).

## Dashboards (sub-project 12)

Grafana (`grafana/grafana-oss:13.0.2`, `mem_limit` 256 MiB, container `oj-grafana`) is at `http://127.0.0.1:3000`
(plain HTTP, loopback only, like the other operator UIs). Log in as `admin` with `GRAFANA_ADMIN_PASSWORD` from `.env`.
Everything is provisioned read-only from `grafana/`, so a dashboard is changed in the repo, not in the UI.

- **Datasource:** `prometheus` (uid `prometheus`, `http://prometheus:9090`, the default).
- **Dashboards** (folder-less, tag `oj`): *OJ Overview* (`oj-overview`: verdicts per minute, judge latency p50/p95, queue
  depth, calls refused with 503 `QUEUE_FULL` per minute (submits and admin rejudges), 5xx rate and p95 latency per service, firing alerts, a
  pointer to Jaeger), *Infrastructure* (`oj-infrastructure`:
  host CPU, memory and disk; container CPU and memory from cAdvisor; Postgres connections; Redis memory; Kafka consumer
  lag) and *JVM* (`oj-jvm`: heap, GC pause time and live threads, with a `job` variable). The HighErrorRate, HighLatency and
  HostDiskAlmostFull expressions are the ones in `alerts.yml`, so a panel shows what the alert sees. The Infrastructure
  panels fill in once the exporters (sp12 task 15) are running.
- **The admin password applies only on first start.** `GF_SECURITY_ADMIN_PASSWORD` is read when the `grafanadata` volume is
  first created. A later change of `GRAFANA_ADMIN_PASSWORD` in `.env` does nothing; set the new value with
  `docker exec -it oj-grafana grafana cli admin reset-admin-password`, typing it at the prompt (never on a command line,
  where it would land in the shell history and the process list), then update `.env` to match.
- **No Jaeger datasource (deviation from spec 3.4).** Jaeger 2.21.0 removed the v1 HTTP endpoints Grafana's Jaeger
  datasource uses (release note #9260; `/api/services` answers 404). Checked on 2026-10-20 with a throwaway Grafana 12.0.2:
  the datasource health check fails ("cannot unmarshal number into ... ServicesResponse"), also with
  `GF_FEATURE_TOGGLES_ENABLE=jaegerEnableGrpcEndpoint`, which 12.0.2 accepts but which changes nothing for the health check.
  Traces are read in Jaeger's UI, `http://127.0.0.1:16686`; OJ Overview has a text panel that says so. Revisit when
  Grafana's Jaeger datasource speaks Jaeger v2's API.
- **Plugins:** `GF_PLUGINS_PREINSTALL_DISABLED=true`. By default Grafana 12 downloads three Grafana-Labs apps at start.
- **Bench:** `grafana` is in profile `off` there.
- Check: `bash tests/grafana.test.sh` (throwaway `prom/prometheus:v3.15.0` and Grafana: every panel query is valid, the
  three dashboards load) and the Grafana checks in `tests/compose.test.sh`.

## Configuration

Shared knobs live in **`.env`**. No service loads it through `env_file`: each gets only the variables it
needs through `${VAR}` interpolation, and its database settings from its own file (`.env.identity`,
`.env.problem`, `.env.submission`).
Copy `.env.example` → `.env` to start from a clean template.

Notes:
- `api-gateway` does **not** load `.env`; compose passes it only the service URIs, the profile and
  the OpenTelemetry settings. submission-service is not published on the host — everything goes
  through the HTTPS edge (`https://localhost/api/v1`; the gateway has no host port).
- `.env` holds **container-network** addresses (`kafka:29092`). The worker's sandbox URLs are fixed in compose
  (`https://judge-server:8080,https://judge-server-2:8080`).
- `.env` and every `.env.<service>` hold secrets: keep them mode 600 (`chmod 600 .env`).
- One `JUDGE_SERVER_TOKEN` is shared by api, worker, and judge-server.
- `problem-service` does not load `.env` either: it reads `.env.problem` (its database) and compose
  passes it MinIO and Kafka; submission-service likewise reads `.env.submission` plus Kafka, Redis and
  the judge-server token. submission-service calls problem-service's gRPC API over mutual TLS: its
  certificate (CN `submission-service`) replaced `PROBLEM_RPC_TOKEN`.
- `submission-service` runs the profile in `.env.submission` (the image's default is **dev**, baked in via
  `pom.xml`); both serve the API on **8000** and actuator on **8081**.
- `GOOGLE_REDIRECT_URI` must match the Google console. It points at the Vite dev origin
  (`:5173`); if you drive OAuth through the containerized portal (`https://<OJ_PUBLIC_HOST>`), update
  both the `.env` value and the console.
- Google sign-in links an existing account that has no Google id yet (for example one an admin created) only when
  Google vouches for the address: a `@gmail.com` address, or a Google Workspace account. Any other Google account with
  that email is refused (`reason=GOOGLE_LINK_NOT_ALLOWED`) and its owner signs in with the password. A Google account
  whose email matches no account still gets a new one.

### Run lane (custom test cases)

The portal's **Run** button (`POST /api/v1/submissions/run`, `docs/superpowers/specs/2026-10-24-run-code-design.md`)
judges the user's code on the sample case and their own inputs and answers synchronously; nothing is stored. It goes
through its own lane: submission-service publishes `run.requested` (the cases inline, a deadline) and waits for
`run.judged`; **`run-worker`** — the judge-worker image on its own topics, consumer group `run-workers` and certificate
identity `run-worker`, no MinIO, no heartbeat relay — judges in the same sandboxes. Submit never queues behind Run and
Run never behind Submit.

- **submission-service instances:** each instance reads all of `run.judged` in a consumer group of its own,
  `run-results-<RUN_INSTANCE_ID, else HOSTNAME>` (ACL: `kafka/acls.sh`, prefix `run-results-`), and completes only the runs
  whose reply names it: the request carries `replyTo` (the instance's id) and the worker echoes it. The pending runs live in
  the memory of the instance that took the request, so with one shared group a reply could reach the wrong instance and end
  in 504. A reply that names another instance is dropped silently; one without `replyTo` (an older worker, a run in flight
  during an upgrade) is tried by every instance, as before. Admission (`RUN_MAX_INFLIGHT`) is still per instance.
- **Replicas:** two by default (`deploy.replicas`); `docker compose up -d --scale run-worker=N` changes it. One replica
  judges one run at a time (the sandbox runs a run's cases in parallel, not runs).
- **submission-service knobs** (`.env`, optional): `RUN_COOLDOWN_SECONDS` (3, per user), `RUN_MAX_INFLIGHT` (20: runs
  one instance keeps waiting; beyond it 503 `RUN_BUSY` — keep it around replicas × 10), `RUN_TIMEOUT` (45s: then 504
  `RUN_TIMED_OUT`, and the worker skips a run past its deadline — `oj_run_expired_total`). Also one pending run per
  user (429 `RUN_IN_PROGRESS`); limits of 6 cases and 64 KiB per input or expected output are fixed in the service.
- **Rollout (once):** add `run-worker` to `pki/identities.txt` (done), `pki/pki.sh issue run-worker`, then
  `docker compose up -d`: `tls-init` installs the certificate, `kafka-init` adds the ACLs (`kafka/acls.sh`),
  submission-service creates the topics, the replicas join. Rollback: stop `run-worker`, redeploy the previous
  submission-service image; the topics and ACLs persist harmlessly.
- **Alert:** `RunWorkerDown` (warning) when no replica answers its scrape (job `run-worker`, found through DNS like
  `judge-worker`). Metrics: `oj_run_*` on submission-service (latency, outcome, inflight, refused, timed_out,
  late_replies, unreadable_replies), `oj_run_expired_total` on the run-workers.

### Root admin password

identity's V2 migration seeds the root admin `admin` with a published default password, and the `DefaultAdminPassword`
alert (gauge `oj_identity_default_admin_password`) fires until it is changed. On this host it was changed on
2026-10-21 and the new one is `OJ_ADMIN_PASSWORD` in `.env` (0600, in the restic backup with the other secrets; compose
does not read it). Read it without printing it, for example for the seed loader:
`OJ_PASSWORD=$(grep '^OJ_ADMIN_PASSWORD=' .env | cut -d= -f2-) python3 seed/problems/load.py`. To change it again:
`PUT /api/v1/users/me/password` as the admin (`currentPassword`, `newPassword`; every admin session ends), then update
`.env`. The bench stack seeds its own throwaway identity-db and keeps the default (`BENCH_ADMIN_PASSWORD` overrides it).

### Overload and verdict-correctness knobs (sub-project 11)

Defaults are in the services; none of these needs setting. submission-service reads the first three from
`.env.submission` (its `env_file`); the worker's is not passed by compose, so changing it means adding
`JUDGE_INFRA_RETRY_SECONDS` to the `judge-worker` `environment` (and to the allowlist in `tests/compose.test.sh`).

| Variable | Default | Meaning |
|---|---|---|
| `JUDGE_JUDGING_TIMEOUT` | `3m` | A JUDGING submission older than this is marked SYSTEM_ERROR (`Judging timed out`). Replaces `JUDGE_STUCK_TIMEOUT_MIN`. |
| `JUDGE_PENDING_TIMEOUT` | `30m` | A PENDING submission whose judge request left the outbox longer ago than this is marked SYSTEM_ERROR (`Judging request lost`) — but only when no worker has started an *older* submission in the last `JUDGE_PENDING_PROGRESS_WINDOW`. A long queue drained in order is waiting, not lost; one that newer submissions overtook (its record was skipped) or nobody works on is failed. A request whose outbox row is dead (`OutboxDeadRow`) counts as not sent. |
| `JUDGE_PENDING_PROGRESS_WINDOW` | `5m` | How far back the PENDING rule looks for a worker's start (`submission.started`) of an older submission before it believes a request was lost. After the last worker dies, queued submissions fail at most this long after the timeout. |
| `JUDGE_MAX_QUEUE_DEPTH` | `500` (live: `200`) | PENDING + JUDGING submissions allowed at once; beyond it a submit gets 503 `QUEUE_FULL` with `Retry-After: 30` (counted in `oj_admission_refused_total`). A problem rejudge queues only as many of its newest submissions as there are free slots, and gets 503 only when there is none. |
| `JUDGE_INFRA_RETRY_SECONDS` | `300` | Worker: how long it retries MinIO / sandbox failures (2 s, 4 s, 8 s ... capped at 60 s) before giving up with `Judge infrastructure unavailable`. |

Sizing `JUDGE_MAX_QUEUE_DEPTH`. The wait of the last queued submission is about depth ÷ verdict throughput, and one
worker gives about 0.37 verdicts/s on A+B (`bench/REPORT.md` §4: 2.20/s for 6 workers). The code default 500 is sized
for the 6-worker bench (judge p95 292 s at 500, REPORT §13). Live runs `200` (`.env.submission`): about 9 minutes with
the one worker, under the 30-minute PENDING timeout. **Scaling the workers means raising the cap**, and the
`JudgeQueueBacklog` threshold (150) must stay below the cap, or the alert can never fire. A problem rejudge on a busy
queue queues only the newest submissions that fit; its answer's `queued` says how many.

With the live cap (200) below the batch size (500), even an idle queue takes at most the free slots. A repeated
**unfiltered** problem rejudge takes the newest finished submissions again, including the ones it just rejudged, so the
older ones are never reached. To reach them, filter with `?status=<verdict>` (rows that change verdict leave the filter),
rejudge them one by one, or raise `JUDGE_MAX_QUEUE_DEPTH` for the operation.

The bench stack (`bench/`) reads these same env files, so a bench run inherits `JUDGE_MAX_QUEUE_DEPTH=200` from
`.env.submission`. `bench/REPORT.md` §13 was measured at 500: a run that needs 500 must set it on purpose and say so in
its report. It also reads the same `.env.identity`, where the access token now lives 15 minutes
(`JWT_ACCESS_TOKEN_EXPIRATION=900000`, `migrations/sp12-env.sh`); `bench/k6` logs every user in once in `setup()`, so a
k6 phase that runs longer than 15 minutes after its login meets expired access tokens. Today's runs fit (the longest
step is 600 s); this is a limit to remember when adding a longer one.

### Login limits (sub-project 12)

identity-service counts failed password logins in Redis (the pair and the account count a login before its password is
checked, so a burst of guesses cannot get past them):

- per (username, IP) pair: 5 failures in 5 minutes lock that pair for 15 minutes (keys `oj:rl:login:pair:<username>|<ip>`);
  the 4th and 5th failures also wait 2 s and 4 s;
- per account: 50 failures in an hour lock the username for 15 minutes, from any address (`oj:rl:login:account:<username>`);
- per IP: 30 failures in 5 minutes lock every login from that address for 15 minutes, correct passwords included
  (`oj:rl:login:ip:<ip>`). Only failures count toward it: correct logins never do, however many arrive at once;
- `PUT /users/me/password`: the check takes a place before the current password is checked, 5 places per 5 minutes per
  user (`pwchange:<user id>`), so parallel guesses cannot all reach the password check. The sixth request is the single
  probe and everything after it gets `429`. A 5th wrong current password locks password changes for 15 minutes. A
  success, or an outcome that says nothing about the current password (`PASSWORD_UNCHANGED`, `PASSWORD_INVALID`), hands
  its place back.

Known limits, both the spec's values for sub-project 12 and a follow-up: a lab behind one NAT address shares the IP
limit, so 30 wrong passwords from the whole lab within 5 minutes lock every login from it for 15 minutes; and anyone can
keep one account locked by sending wrong passwords for it (50 an hour is enough). An account also counts its logins
still in flight, so more than 50 simultaneous logins to one shared account (a class on a demo account) get `429` with
`Retry-After: 2` until the one attempt let past the limit has been checked, and a wrong password among them locks the
account for 15 minutes. As correct logins do not count toward the IP limit, it is decided after the password check: a
burst of parallel guesses against many different usernames from one address gets a password check each until the 30th
failure locks the address, as before sub-project 12 (the pair and account limits still bound each account).

For a lab or a contest, raise the limits before the session in `.env.identity`: `OJ_LOGIN_IP_LIMIT` (default 30; for
example `OJ_LOGIN_IP_LIMIT=300` for a hall of 150 behind one address) and `OJ_LOGIN_ACCOUNT_LIMIT` (default 50; for a
shared account), then `docker compose up -d --no-deps identity-service` to recreate it. Both must be at least 1:
identity-service refuses to start with a lower value (0 included) and names the variable in the error. To relax the
limits for a contest, raise them; there is no setting that turns them off.

There is **no admin endpoint** to clear a lock. A lock ends by itself after 15 minutes. To clear one earlier, delete both
the lock key and the counter of the same suffix in Redis (with only the lock gone, a counter over its limit locks the
key again at the next attempt, or for an address at the next failure), for example for the pair `alice|10.0.0.5`:

```bash
docker exec oj-redis redis-cli --tls --cacert /etc/oj/tls/ca.crt --cert /etc/oj/tls/tls.crt --key /etc/oj/tls/tls.key \
  del 'oj:rl:lock:pair:alice|10.0.0.5' 'oj:rl:login:pair:alice|10.0.0.5'
```

For an account use `oj:rl:lock:account:<username>` and `oj:rl:login:account:<username>`; for an address,
`oj:rl:lock:ip:<ip>` and `oj:rl:login:ip:<ip>`. Redis fails open: while it is down, no limit applies.

### Sessions (sub-project 12)

An access token lives `JWT_ACCESS_TOKEN_EXPIRATION` (15 minutes), and its cookie lives exactly as long; the refresh
cookie lives 7 days at `Path=/api/v1/auth`, but the session itself ends `JWT_REFRESH_TOKEN_EXPIRATION` (3 days) after
the login, however often it is refreshed (rotation keeps the first login's expiry). A disable, a soft delete, a role change, a password change or reset, a
refresh-token reuse and a logout end every session of the user at once: identity-service writes a cutoff
(`oj:token:revoked-before:<user id>`) and the gateway strips every access token of that user issued before it. The cutoff
stays in Redis for `OJ_SESSION_REVOCATION_MARKER_TTL` (default `25h`, never less than the access-token lifetime plus a
minute), so it also covers the 1-day access tokens issued before sub-project 12 was deployed; a 16-minute cutoff would
let those back in for the rest of their day. The cost is one small Redis key per revoked user for 25 hours.

Revocation precision (sub-project 14). identity-service now puts the claim `iat_ms` (issue time in epoch milliseconds)
in every access token, and a revocation writes a second cutoff, `oj:token:revoked-before-ms:<user id>`, next to the
seconds key. The gateway compares a token that has `iat_ms` against the millisecond cutoff, so a login a few
milliseconds after a logout or a role change keeps its session. The gateway's old 2-second rule (a whole-second
comparison) now applies only to tokens minted before sub-project 14 was deployed, which are gone within 15 minutes. The
order of deployment does not matter: an older gateway reads the seconds key as before, and a newer gateway falls back to
it for any token without `iat_ms`. Nothing needs configuring.

### Handles, checker keys, avatars and logs (sub-project 14)

Public handles. A Google account no longer has its email address as its username. A new Google sign-in gets a handle
made from the Google display name: diacritics removed (Vietnamese included, `đ` becomes `d`), lowercase, letters,
digits and `_` only, at most 32 characters, and a numeric suffix (`_2`, `_3`, ...) if the handle is taken. A name that
leaves nothing usable becomes `user` plus 6 random hex digits. The email address is never used for the handle and stays
in the `email` field. Notes for the operator:

- identity's Flyway migration V8 replaced the email usernames of the existing accounts when sub-project 14 was deployed
  (the oldest account gets the plain handle). Soft-deleted accounts keep theirs. V8 logs only a count.
- An admin password reset on a Google account logs in with the handle, not the email address. Tell the user the handle
  (`GET /api/v1/users/<id>` as an admin shows it).
- Admin search by email in the submission list is gone: `/users/public/<name>` answers `404` for any name containing
  `@`, for every caller. Admins search submissions by handle, and find a user by email only in the user list.
- Rollback: V8 stays. An older identity image starts on a V8 database (Flyway ignores a newer migration) and serves the
  handles as usernames. A Google account created during a rollback gets an email username again; it gets its handle at
  its next sign-in on sub-project 14. Going back to email usernames would need a backup taken before the deploy and
  would undo everything written since, so it is not offered.

Checker sources. problem-service stores a custom checker at `sources/<slug>/spj-<sha256>.cpp` in the test-case bucket,
where the hash is the problem's checker version. An upload never overwrites or deletes another key, and removing a
checker deletes nothing, so old keys stay (at most 64 KiB each) and no clean-up job exists yet. A checker stored under
the old key `sources/<slug>/spj.cpp` is still read while its hash matches the version. After a rollback to the
sub-project 13 image, re-upload any checker that was uploaded on sub-project 14: the older image reads only
`spj.cpp`. When the stored source does not match its version, the judge spec fails and the submit is refused with
`PROBLEMS_UNAVAILABLE` (503). problem-service logs a WARN; submission-service logs an ERROR line,
`checker source missing for <slug>`, besides the handler's WARN `PROBLEMS_UNAVAILABLE (503), Retry-After 5s`.

Avatars. Public profile reads (`/users/public/...`) carry no avatar at all, and every profile page shows initials
only, the owner's own included. The header's account menu and the admin screens (the admin layout and `/admin/users`)
still show the Google picture, and the portal loads it with `referrerpolicy="no-referrer"`, so Google sees no page
address.

Logs. A 4xx answer with an error code logs one WARN line, `CODE (status): message`, with no stack trace; that
includes 404 codes such as `USER_NOT_FOUND`. Other 4xx answers also log one WARN line with no stack trace, in their own
form (`Bad request: ...`, `Already exists: ...`, `Validation failed: ...`, `Access denied: ...`, and `No resource: ...`
or `No handler: ...` for an unknown path); an invalid argument whose message is withheld still logs its stack trace.
Two answers log only at DEBUG, so they do not show at the default level: a 404 for a missing record (`Not found: ...`)
and a 429 rate-limit refusal (`CODE (429), Retry-After Ns`). A 5xx refusal that is a deliberate overload answer
(`ACCOUNT_BUSY`, `QUEUE_FULL`, `STREAMS_FULL`, `PROBLEMS_UNAVAILABLE`) logs one WARN line, `CODE (status), Retry-After
Ns`. Other 5xx answers keep their ERROR and stack trace, and a missing checker source also logs an ERROR line in
submission-service (see Checker sources). When looking for a refusal, grep for the code, for example
`docker logs oj-identity-service 2>&1 | grep ACCOUNT_BUSY`.

Dependabot. The `ignore` rules in the repos' `.github/dependabot.yml` (springdoc majors, Spring Cloud minors and
majors, the docker `maven` image) also suppress security-update PRs: a security alert on springdoc or Spring Cloud
whose fix needs a Boot 4 line is handled by hand (the alert still shows in the Security tab).

### Deploying sub-project 11: backfill `last_status`, check the statistics

Once, after problem-service has started with Flyway V5 and before any rejudge, from `judge-deployment/`:

```
migrations/sp11-last-status.sh     # fills t_processed_verdicts.last_status from submission-db; prints "backfilled <n> last_status value(s)"
scripts/stats-check.sh             # PASS, or one "MISMATCH <problem_id> <verdict> submissions=<a> stats=<b>" line per difference (exit 1)
```

The backfill only touches rows where `last_status` is NULL, so it can be run again (the second run prints
`backfilled 0`). A rejudge of a submission whose `last_status` is still NULL leaves the statistics alone. PENDING and
JUDGING submissions are not counted by either side; every terminal status is. Both scripts use `docker exec ... psql`
over the Unix socket and print counts only; `SUBMISSION_DB_CONTAINER` and `PROBLEM_DB_CONTAINER` override the container
names. `bash tests/sp11-stats.test.sh` checks them on throwaway containers.

Rollout notes. After deploying sub-project 11, look for `republishing <slug> failed` in the problem-service log: a
problem that fails keeps the `.bundle-format` marker unwritten, so the republish pass runs again on every start until it
succeeds. After a rollback during which a test case was edited, remove the marker before deploying sub-project 11
again, so the pass re-runs (inside `oj-minio`, over TLS, as `backup/backup.sh` does; `$BUCKET` is `MINIO_BUCKET`):

    docker --context default exec -e BUCKET="$MINIO_BUCKET" oj-minio sh -c \
      'SSL_CERT_FILE=/etc/oj/tls/ca.crt MC_HOST_local="https://$MINIO_ROOT_USER:$MINIO_ROOT_PASSWORD@localhost:9000" mc rm "local/$BUCKET/.bundle-format"'

### Replaying a dead-letter topic

Alert `VerdictDeadLettered` (verdicts on `submission.judged.dlq` not applied) and `ProblemStatsDeadLettered`
(records on `oj.submission.events.dlq` not counted) mean a consumer gave up on a record. Fix the cause first
(the service log names it), then copy the records back:

    scripts/replay-dlq.sh submission.judged.dlq submission.judged
    scripts/replay-dlq.sh oj.submission.events.dlq oj.submission.events [--max N]

The script runs in `oj-kafka` (override with `KAFKA_CONTAINER`) on its loopback listener, keeps record keys, and
prints `replayed <n> record(s) from <dlq> to <target>`. Its consumer group `dlq-replay` commits offsets, so a
second run copies only records not copied before. It reads for 10 s after the last record, so it takes a little
longer than the copy itself. A replayed record that fails again returns to the dead-letter topic.

If writing to the target fails, the script exits non-zero and prints a reset command, because the group's offsets were
already committed. Run it to read the records again (re-copying is safe: the consumers are idempotent, except for the
rejudge caveat below):

    docker --context default exec oj-kafka /opt/kafka/bin/kafka-consumer-groups.sh --bootstrap-server 127.0.0.1:9092 \
        --group dlq-replay --topic <dlq-topic> --reset-offsets --to-earliest --execute

Replaying `submission.judged.dlq`:

- A replayed verdict applies only to a submission that is still PENDING or JUDGING (status 6 or 7). Once the reconcile
  job marked it SYSTEM_ERROR (`Judging timed out` / `Judging request lost`), the replay is a no-op (the log says
  "late or duplicate verdict"): rejudge that submission instead (`POST /api/v1/submissions/{id}/rejudge`).
- A dead-lettered verdict of an earlier generation (the submission was rejudged since) is ignored: 0 rows, logged as
  late or duplicate. Verdicts carry their generation (`rejudgeCount`) from sub-project 12 on (requests queued by the new submission-service and judged by the new worker); a record without
  one (dead-lettered before that deploy) is still applied as before, so replay those only for submissions not
  rejudged since.
- After a Kafka outage longer than about 2.5 minutes, in-flight judgements may have been timed out; rejudge them with
  `POST /api/v1/problems/{slug}/rejudge?status=5`.

Limits: a record with a null key replays with the literal key `null`; a record containing a raw newline, or no tab
between key and value, cannot be replayed with this script.

**Warning.** Replaying `oj.submission.events.dlq` is safe for first verdicts. A REJUDGE event replayed after a newer
rejudge of the same submission moves the statistics back to the older verdict (the event has no ordering field).
Replay rejudge events only when no newer rejudge happened for those submissions, or run `scripts/stats-check.sh`
afterwards.

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
- **Kafka has no host port.** Services and the worker use `kafka:29092` (listener `INTERNAL`: TLS, a client
  certificate from the private CA required). Tools run inside the container (`docker exec oj-kafka …`, the
  healthcheck, the bench drain) use the PLAINTEXT listener `LOCAL` on `127.0.0.1:9092`, which nothing else can reach.
  A client's principal is its certificate's CN, and each service may use only its own topics and consumer group: the
  one-shot `kafka-init` writes those ACLs from `kafka/acls.sh` on every `up`. A new topic or client needs a rule there;
  deleting a rule does not revoke it (`docker exec oj-kafka /opt/kafka/bin/kafka-acls.sh --bootstrap-server 127.0.0.1:9092 --remove …`).
- **MinIO serves TLS only** (`https://minio:9000`; the console on `https://127.0.0.1:9001`), with the `minio` certificate
  from the private CA. problem-service (read, write, delete) and the worker (read only) each use their own key from
  `.env` (`MINIO_PROBLEM_*`, `MINIO_WORKER_*`), limited to the test-case bucket; only `minio` and the one-shot
  `minio-init` get the root account. `minio-init` creates the bucket, the policies (`minio/policies`) and the two users
  on every `up` and never touches objects. `mc` inside `oj-minio` needs an `https://` alias; the container's
  `SSL_CERT_FILE` points it at the CA.
- **Sandbox health and the admin "Judge servers" page.** Compose replaces the image's own healthcheck
  (QingdaoU's heartbeat script, which always exited 1 here) with a call to the sandbox's `/ping` (mutual TLS with the
  sandbox's own certificate: gunicorn serves `:8080` only to clients with a certificate from the CA), and
  `judge-worker` waits for `service_healthy`. The sandboxes sit on the internal `sandbox-net` and cannot
  reach submission-service, so `judge-worker` relays each one's `/ping` to `t_judge_servers` every 10 s
  (`SANDBOX_HEARTBEAT_URL`); rows are keyed by the fixed hostnames `judge-server` / `judge-server-2`. The
  registry stores the worker's IP for them, not the sandbox's. Rows from before the fixed hostnames
  (one per old container id) stay "Offline" until deleted.
- **Java and Go run without a qduoj seccomp filter (open item, sub-project 15).** `t_languages.seccomp_rule` is NULL for Java
  and `''` for Go (`V2__seed_languages.sql`); C, C++ and Python 3 have `c_cpp`/`general`. As far as I recall qduoj's own
  configuration also gives Java no rule, because the JVM needs threads and many syscalls (not verified here). What still
  bounds such a submission: the judger's rlimits (CPU, real time, memory, output), the unprivileged run user (uid 12002), the
  container's `cap_drop`/`no-new-privileges`/read-only root/`pids_limit`, and `sandbox-net` (no route out). It does *not* bound
  one submission against another on the same sandbox (shared uid and PID namespace) or a fork bomb against the container's
  `pids_limit`. Not changed blind, because a rule the JVM or the Go runtime cannot live under turns every submission in that
  language into a runtime error. To decide on the host that runs the stack: judge a+b in each language, then a program that
  forks or opens a socket, with the candidate rule set by hand in `t_languages` (Go: `golang`; Java: only a rule that still
  passes a+b). If a rule passes, add it as the next Flyway migration in oj-submission-service
  (`UPDATE t_languages SET seccomp_rule = '<rule>' WHERE identifier = '<language>'`) and list the date and result here; if
  none does, either accept the isolation above or disable the language (`is_disabled = true`).
- **Legacy stacks may still be running** on the snap daemon (`judge-server` and `my-oj`
  compose projects — the scattered files this directory replaces). They coexist with this
  stack but are redundant; stop them when convenient (their privileged containers may need
  elevated privileges to stop).
