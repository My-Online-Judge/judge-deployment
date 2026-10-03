# judge-deployment

**Single source of truth** for running the whole Online Judge system with Docker Compose.
Every service is containerized; all configuration lives in this directory. Build contexts
reference the sibling repos (`../judge-api`, `../oj-identity-service`, `../oj-api-gateway`, `../oj-common`, `../judge-portal`,
`../judge-worker`, `../mock-judge-server`) — no source is copied here.

> This directory supersedes the scattered compose files
> (`../docker-compose.integration.yml`, `../docker-compose.mock.yml`,
> `../judge-api/docker-compose.yml`, `../judge-server/docker-compose.yml`). Those are kept
> as legacy references; prefer this stack.

## Architecture

```
Browser
  ├─ http://localhost        → judge-portal   (nginx:80, static Vue 3 build)
  └─ http://localhost:8000   → api-gateway    (Spring Cloud Gateway: CORS, client-IP boundary)
                                   └─ /api/v1/** → judge-api (Spring Boot, internal :8000 only)
                                                     ├── db      (Postgres 16, my_oj)
                                                     └── kafka  ──produce→ submission.requested
                                                                ←consume── submission.judged
                                                                      │
                                                                judge-worker (Python, kafka-python)
                                                                      │  HTTP POST /judge
                                                                      └→ judge-server ×2 (qduoj sandbox, privileged)
                                                                            └─ heartbeat → judge-api:8000 /api/judge_server_heartbeat/
Traces: api-gateway, judge-api, judge-worker ──OTLP──→ jaeger (UI http://127.0.0.1:16686)
```

## Services

| Service        | Image / Build            | Host port | Purpose                          |
|----------------|--------------------------|-----------|----------------------------------|
| `db`           | `postgres:16`            | 5433      | Application database (`my_oj`)   |
| `kafka`        | `apache/kafka:3.9.0`     | 9092      | Submission event bus (KRaft)     |
| `api-gateway`  | build `../oj-api-gateway`| 8000      | Public API entry (CORS, client IP)|
| `judge-api`    | build `../judge-api`     | — (internal) | Problems, submissions, judging |
| `identity-service` | build `../oj-identity-service` | — (internal) | Login, users, roles, bans; issues the tokens |
| `identity-db`  | `postgres:16`            | — (internal) | identity-service's database (`identity`) |
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
docker compose logs -f judge-api judge-worker

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
| Kafka       | localhost:9092                   |
| Postgres    | localhost:5433 (user `postgres`) |

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

## Configuration

All knobs live in **`.env`** (committed dev values). `judge-api` and `judge-worker` load it
via `env_file`; `db` and `judge-server` read individual vars via `${VAR}` interpolation.
Copy `.env.example` → `.env` to start from a clean template.

Notes:
- `api-gateway` does **not** load `.env`; compose passes it only `MONOLITH_URI`, the profile and
  the OpenTelemetry settings. judge-api is no longer published on the host — everything goes
  through the gateway on :8000.
- `.env` holds **container-network** addresses (`db`, `kafka:29092`, `judge-server`) — it is
  intentionally separate from `judge-api/.env` (bare-metal `localhost`).
- One `JUDGE_SERVER_TOKEN` is shared by api, worker, and judge-server.
- `judge-api` runs the **dev** profile (Postgres-backed) — this is baked into its image via
  `pom.xml` (`activeByDefault`), which also fixes the port to **8000**.
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
  `judge-api:8000` and registers in `t_judge_servers`. Nothing depends on its health
  (`judge-worker` waits on `service_started`).
- **Legacy stacks may still be running** on the snap daemon (`judge-server` and `my-oj`
  compose projects — the scattered files this directory replaces). They coexist with this
  stack but are redundant; stop them when convenient (their privileged containers may need
  elevated privileges to stop).
