# judge-deployment

**Single source of truth** for running the whole Online Judge system with Docker Compose.
Every service is containerized; all configuration lives in this directory. Build contexts
reference the sibling repos (`../judge-api`, `../judge-portal`, `../judge-worker`,
`../mock-judge-server`) — no source is copied here.

> This directory supersedes the scattered compose files
> (`../docker-compose.integration.yml`, `../docker-compose.mock.yml`,
> `../judge-api/docker-compose.yml`, `../judge-server/docker-compose.yml`). Those are kept
> as legacy references; prefer this stack.

## Architecture

```
Browser
  ├─ http://localhost        → judge-portal   (nginx:80, static Vue 3 build)
  └─ http://localhost:8000   → judge-api      (Spring Boot, profile=dev, base /api/v1)
                                   ├── db      (Postgres 16, my_oj)
                                   └── kafka  ──produce→ submission.requested
                                              ←consume── submission.judged
                                                    │
                                              judge-worker (Python, kafka-python)
                                                    │  HTTP POST /judge
                                                    └→ judge-server (qduoj sandbox, privileged)
                                                          └─ heartbeat → judge-api:8000 /api/judge_server_heartbeat/
```

## Services

| Service        | Image / Build            | Host port | Purpose                          |
|----------------|--------------------------|-----------|----------------------------------|
| `db`           | `postgres:16`            | 5433      | Application database (`my_oj`)   |
| `kafka`        | `apache/kafka:3.9.0`     | 9092      | Submission event bus (KRaft)     |
| `judge-api`    | build `../judge-api`     | 8000      | Spring Boot backend (dev profile)|
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
| Swagger UI  | http://localhost:8000            |
| Kafka       | localhost:9092                   |
| Postgres    | localhost:5433 (user `postgres`) |

## Configuration

All knobs live in **`.env`** (committed dev values). `judge-api` and `judge-worker` load it
via `env_file`; `db` and `judge-server` read individual vars via `${VAR}` interpolation.
Copy `.env.example` → `.env` to start from a clean template.

Notes:
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
