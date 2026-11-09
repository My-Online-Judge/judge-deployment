# Go Judge Server Implementation Plan (part 2 of 2: worker client, migrations, compose cut-over)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Point the Python worker at the Go sandbox over gRPC, prepare the language rows, swap the compose stack and
prove parity, so qduoj can be removed.

**Architecture:** The worker keeps its shape: `dispatcher.py` swaps `requests` for a gRPC stub and converts the
`JudgeResponse` back into today's dict at that boundary, so `handler.py`/`verdict.py` are untouched. Two Flyway
migrations adjust `t_languages`. Compose replaces the `x-sandbox` image and caps; the Python mock is replaced by the
Go image's `mock` subcommand.

**Tech Stack:** Python 3.11, `grpcio` 1.68+, `grpcio-tools` (generation only, committed stubs), pytest; Flyway SQL;
Docker Compose.

**Spec:** `judge-deployment/docs/superpowers/specs/2026-11-08-go-judge-server-design.md` (§N). Depends on part 1
(`2026-11-08-go-judge-server.md`) for the proto and the image.

## Global Constraints

- Worker env names unchanged: `JUDGE_SERVER_URL` comma list, values `host:port` or `https://host:port` (scheme
  stripped); `JUDGE_SERVER_TOKEN`; token metadata key `x-judge-server-token` = sha256 hex (§4.2).
- New worker env: `JUDGE_TIMEOUT_MAX_SECONDS` default 300 (§8).
- Failover table §4.2 is the law: `UNAVAILABLE`/`INTERNAL`/connection → fail over + mark down; `RESOURCE_EXHAUSTED`
  → next sandbox, not marked down; everything else → raise, no failover; `DEADLINE_EXCEEDED` → raise, no failover.
  `infra_errors.transient_reason`: `UNAVAILABLE`, `INTERNAL`, `RESOURCE_EXHAUSTED` → `"sandbox"`; others `None`.
- The dict produced by `response_to_dict` is exactly today's wire shape: `{"err": None, "data": [case dicts]}` with
  keys `cpu_time, real_time, memory, signal, exit_code, error, result, test_case, output_md5, output`; or
  `{"err": "CompileError"|"SPJCompileError", "data": message}`.
- Migrations are safe on qduoj and on the Go sandbox (§7): V10 any time, V11 only with the cut-over release.
- Compose sandbox: `mem_limit: 1536m`, `cpus: 2`, tmpfs `/work:exec,mode=755,size=512m` and `/tmp:size=64m`, same six
  caps, `read_only`, `no-new-privileges`, `sandbox-net`, `/test_case:ro`, `java-policy` config mount kept.
- Commit messages one line, imperative, repo prefix convention, no attribution; branch `feat/go-judge-server`; no
  pushes or PRs by the agent.

## Review Focus

1. A sandbox answer with fewer `cases` than `test_case_number` must still become SYSTEM_ERROR via
   `verdict.incomplete_reason` after conversion: `response_to_dict` must not pad or drop. Test in Task 3.
2. Every sandbox `UNAVAILABLE` for 6 minutes: judge-worker must still end in SYSTEM_ERROR "Judge infrastructure
   unavailable" at `JUDGE_INFRA_RETRY_SECONDS`, not loop forever; run-worker in 30 s. Test in Task 4.
3. `Output` bytes that are not UTF-8 (a program printing binary): `response_to_dict` must produce a `str` the JSON
   event can carry (`decode("utf-8", errors="replace")`) and `event_limits` caps still apply. Test in Task 3.
4. A TLS failure (wrong CA): `_is_certificate_failure` must recognise the gRPC form (`UNAVAILABLE` with
   `ssl`/`certificate` in `details()`) and not retry it for 300 s. Test in Task 4.
5. Heartbeat relay when the sandbox's `PingResponse` has `running_jobs`: `JudgeServerHeartbeatDto` ignores unknown
   fields (verified in the brainstorm), so the relay posts it and the registry stays green. Test in Task 5.

---

### Task 1: Migration V10, Python 3 compiles to a flat `.pyc`

**Files:**
- Create: `oj-submission-service/src/main/resources/db/migration/V10__python3_flat_pyc.sql`
- Modify: `oj-submission-service/src/test/java/vn/thanhtuanle/SubmissionSchemaTest.java:65` (versions list) and add an assertion

- [ ] **Step 1: Failing test** — in `submissionDbHoldsTheFourSubmissionTablesAndTheLanguages`, extend the versions list with `"10"` and add: `assertThat(jdbc.queryForMap("SELECT compile_command, exe_name FROM t_languages WHERE identifier = 'python3'")).containsEntry("exe_name", "solution.pyc").containsEntry("compile_command", "/usr/bin/python3 -c __import__('py_compile').compile('{src_path}',cfile='{exe_path}',doraise=True)");`
- [ ] **Step 2: Run** `./mvnw -q test -Dtest=SubmissionSchemaTest` (needs Docker) — Expected: FAIL on the versions list.
- [ ] **Step 3: Write V10** — header comment (why: the Go sandbox's Python 3 is 3.10, the artifact must not carry the CPython version; the command has no spaces inside the `-c` argument because commands are split on single spaces; runs unchanged on qduoj's 3.6); `UPDATE t_languages SET compile_command = '...', exe_name = 'solution.pyc', updated_at = now() WHERE identifier = 'python3';`
- [ ] **Step 4: Run** — Expected: PASS.
- [ ] **Step 5: Commit** — `git -C oj-submission-service checkout -b feat/go-judge-server` then `feat(languages): compile Python 3 to a flat solution.pyc so the artifact does not pin the CPython version`

---

### Task 2: Migration V11, re-enable JavaScript and PHP (ships only with the cut-over)

**Files:**
- Create: `oj-submission-service/src/main/resources/db/migration/V11__enable_javascript_php.sql`
- Modify: `SubmissionSchemaTest.java` (versions `"11"`, assertion `SELECT count(*) FROM t_languages WHERE is_disabled` → 0)

- [ ] **Step 1: Failing test** as above. **Step 2: Run** — FAIL.
- [ ] **Step 3: Write V11** — comment: V3 disabled them because the qduoj image lacks node and php; the Go image has both; this migration must be deployed together with the Go sandbox (part 2 Task 7) and the rollback SQL is in `judge-deployment/README.md`. `UPDATE t_languages SET is_disabled = false, updated_at = now() WHERE identifier IN ('javascript', 'php');`
- [ ] **Step 4: Run** — PASS. **Step 5: Commit** — `feat(languages): re-enable JavaScript and PHP for the Go sandbox image`

---

### Task 3: Worker gRPC stubs and dispatcher

**Files:**
- Create: `judge-worker/scripts/gen_proto.sh`, `judge-worker/judge_server_pb2.py`, `judge-worker/judge_server_pb2_grpc.py`, `judge-worker/judge_server_proto.sha256`
- Modify: `judge-worker/requirements.txt` (add `grpcio==1.68.1`, `grpcio-tools==1.68.1`, `protobuf==5.29.1`; keep `requests` for the heartbeat POST), `judge-worker/tls.py` (add `grpc_channel_credentials()`), `judge-worker/dispatcher.py`, `judge-worker/Dockerfile` (no change needed if stubs are committed; `COPY *.py` already takes them)
- Test: `judge-worker/tests/test_dispatcher.py` (rewrite the transport tests), `judge-worker/tests/test_tls.py` (add), `judge-worker/tests/test_proto_stubs.py` (new)

**Interfaces:**
- Produces in `dispatcher.py`:
  - `token_header(token) -> str` (unchanged)
  - `parse_address(url: str) -> str` — `"https://judge-server:8080"` → `"judge-server:8080"`, `"judge-server:8080"` unchanged, `ValueError` on a path or empty host.
  - `build_judge_request(event: dict) -> judge_server_pb2.JudgeRequest` — same field mapping as `build_judge_body` (`src`, `language_config.compile{src_name, exe_name, max_cpu_time→max_cpu_time_ms, max_real_time→max_real_time_ms, max_memory→max_memory_bytes, compile_command, env}`, `run{command, seccomp_rule (None→""), env, memory_limit_check_only (1/0→bool)}`, `max_cpu_time→max_cpu_time_ms`, `max_memory→max_memory_bytes`, `output` default True, `test_case_id` or `test_case` → `InlineTestCases`, spj fields → `Checker{version, src, compile, exe_name, command, seccomp_rule}`). Keep `build_judge_body` only if a test outside the dispatcher still uses it; otherwise delete it.
  - `response_to_dict(resp: judge_server_pb2.JudgeResponse) -> dict` — the exact shapes in Global Constraints; `output` decoded `utf-8` with `errors="replace"`; `cpu_time_ms→cpu_time` etc.
  - `call_judge_server(address, token, request, timeout) -> dict` — one `grpc.secure_channel` (or insecure when TLS is off) per address cached in a module dict, `JudgeServer.Judge(request, timeout=timeout, metadata=[("x-judge-server-token", token_header(token))])`, returns `response_to_dict(...)`.
  - `_is_retryable(exc) -> bool` — `grpc.RpcError` with code in {`UNAVAILABLE`, `INTERNAL`} → True; `RESOURCE_EXHAUSTED` → True but `dispatch_judge` must not `sandbox_health.mark(url, False)` for it (add `_marks_down(exc)`); everything else False.
  - `dispatch_judge(urls, token, request, timeout=30) -> dict` — same loop as today over `parse_address(url)`.
- Produces in `tls.py`: `grpc_channel_credentials() -> grpc.ChannelCredentials | None` (None when TLS off) from `paths()`.
- `scripts/gen_proto.sh`: `python -m grpc_tools.protoc -I ../oj-common/src/main/proto --python_out=. --grpc_python_out=. judge_server.proto && sha256sum ../oj-common/src/main/proto/judge_server.proto > judge_server_proto.sha256`.

- [ ] **Step 1: Generate the stubs** — `pip install grpcio-tools==1.68.1 && scripts/gen_proto.sh`; commit the three files.
- [ ] **Step 2: Failing tests**:
  - `test_proto_stubs.py::test_stubs_match_proto` — skip if `../oj-common/src/main/proto/judge_server.proto` is absent; else sha256 equals the recorded one.
  - `test_dispatcher.py`: `test_parse_address` (3 cases); `test_build_judge_request_maps_fields` (from `_PLAIN_EVENT`: `max_cpu_time_ms == 1000`, `max_memory_bytes == 268435456`, `test_case_id == "prob__abc"`, `output is True`, `HasField("spj") is False`); `test_build_judge_request_spj` (from `_SPJ`: `spj.version == "ab12"`, `spj.compile.src_name == "spj-{spj_version}.cpp"`); `test_build_judge_request_inline` (two cases → `test_case.cases[1].output == "..."`); `test_response_to_dict_results` (two `CaseResult`s → list of two dicts with every key; `output` str); `test_response_to_dict_non_utf8_output` (`b"\xff\xfe"` → str containing U+FFFD); `test_response_to_dict_compile_error` → `{"err": "CompileError", "data": "msg"}`; `test_response_to_dict_spj_compile_error` → `"SPJCompileError"`; `test_response_to_dict_keeps_short_result_list` (1 of 3 → 1 dict; `verdict.incomplete_reason(d["data"], 3)` is not None); `test_dispatch_fails_over_on_unavailable` (fake stub raises `grpc.RpcError` code UNAVAILABLE for the first address → second called, first marked down); `test_dispatch_busy_tries_next_without_marking_down`; `test_dispatch_invalid_argument_raises_at_once` (second address never called); `test_dispatch_deadline_exceeded_raises_at_once`; `test_call_sends_token_metadata`.
  - `test_tls.py`: `test_grpc_credentials_none_without_tls`, `test_grpc_credentials_reads_files(tls_dir)` (uses the fixture; asserts a `grpc.ChannelCredentials` is returned and that a missing file raises).
  Fake the stub by patching `dispatcher._stub(address)` to return an object whose `Judge(request, timeout, metadata)` is a `MagicMock`; build `grpc.RpcError`s with a helper `rpc_error(code, details="")` (subclass `grpc.RpcError` implementing `code()`/`details()`).
- [ ] **Step 3: Run** `pytest tests/test_dispatcher.py tests/test_tls.py tests/test_proto_stubs.py -q` — FAIL.
- [ ] **Step 4: Implement** per the interfaces; delete `call_judge_server`'s `requests` import; `DISPATCHES` counter and `sandbox_health` calls kept.
- [ ] **Step 5: Run** the three files, then the whole suite `pytest -q` — all PASS (`test_handler.py`, `test_verdict.py` unchanged; update `test_handler.py` only where it patches `dispatcher.dispatch_judge` with a body argument name).
- [ ] **Step 6: Commit** — `git -C judge-worker checkout -b feat/go-judge-server` then `feat(dispatcher): call the sandbox over gRPC and convert JudgeResponse to the verdict dict`

---

### Task 4: Transient errors and the scaled deadline

**Files:**
- Modify: `judge-worker/infra_errors.py:21-62`, `judge-worker/handler.py:104-117`, `judge-worker/config.py` (add `JUDGE_TIMEOUT_MAX_SECONDS`)
- Test: `judge-worker/tests/test_infra_errors.py`, `judge-worker/tests/test_handler.py`, `judge-worker/tests/test_config.py`, `judge-worker/tests/test_worker.py` (one end-to-end retry case)

**Interfaces:**
- `infra_errors._is_certificate_failure(exc)`: also True for `grpc.RpcError` with code `UNAVAILABLE` whose `details()` contains `ssl` or `certificate` (case-insensitive).
- `infra_errors.transient_reason(exc)`: `grpc.RpcError` code in {UNAVAILABLE, INTERNAL, RESOURCE_EXHAUSTED} → `"sandbox"`; `DEADLINE_EXCEEDED` → None (sandbox may still be judging); other codes → None. The `requests` branches stay for the heartbeat? No: the heartbeat is not retried through this path; remove the `requests` sandbox branches, keep the MinIO ones.
- `handler.judge_deadline_seconds(config, max_cpu_time_ms: int, case_count: int | None, has_spj: bool) -> int` = `min(config.JUDGE_TIMEOUT_SECONDS + (case_count or 1) * 3 * max_cpu_time_ms / 1000 + (config.SPJ_COMPILE_ALLOWANCE_SECONDS if has_spj else 0), config.JUDGE_TIMEOUT_MAX_SECONDS)`, rounded up; `process_event` uses it in place of lines 111-114.
- `config.JUDGE_TIMEOUT_MAX_SECONDS = _int_env("JUDGE_TIMEOUT_MAX_SECONDS", 300)`; comment: must stay under `MAX_POLL_INTERVAL_MS` (600 s) minus the MinIO budget, and under compose's `stop_grace_period`.

- [ ] **Step 1: Failing tests** — `test_infra_errors.py`: `test_grpc_unavailable_is_sandbox`, `test_grpc_busy_is_sandbox`, `test_grpc_deadline_is_not_transient`, `test_grpc_invalid_argument_is_not_transient`, `test_grpc_tls_failure_is_not_transient`; `test_handler.py`: `test_deadline_scales_with_cases` (30 + 20·3·1 = 90), `test_deadline_capped` (30 + 1000·3·5 → 300), `test_deadline_adds_spj_allowance`, `test_process_event_passes_scaled_deadline` (patch `dispatch_judge`, assert `timeout=`); `test_config.py`: default 300; `test_worker.py`: `test_every_sandbox_unavailable_gives_up_after_budget` (fake `process_event` raising UNAVAILABLE forever, `JUDGE_INFRA_RETRY_SECONDS=10`, fake clock → SYSTEM_ERROR with `GIVE_UP_MESSAGE`).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `pytest -q` — PASS.
- [ ] **Step 5: Commit** — `feat(worker): classify gRPC sandbox errors and scale the judge deadline with the bundle size`

---

### Task 5: Status relay over gRPC

**Files:**
- Modify: `judge-worker/sandbox_status.py`, `judge-worker/sandbox_health.py` (`sandbox_label` accepts `host:port`)
- Test: `judge-worker/tests/test_sandbox_status.py`, `judge-worker/tests/test_sandbox_health.py`

**Interfaces:**
- `sandbox_status.ping(address, token, timeout) -> dict` — `JudgeServer.Ping(PingRequest(), timeout, metadata)` → `{"hostname", "judger_version", "cpu_core", "cpu", "memory", "running_jobs", "max_jobs", "action": "pong"}`.
- `report_once(urls, token, heartbeat_url, timeout=3, *, tls_kwargs=None)` keeps its signature; it calls `ping(parse_address(url), ...)`, marks health, and POSTs the dict plus `action="heartbeat"`, `service_url=url` with `requests` as today (`tls_kwargs` still for that POST).
- `sandbox_health.sandbox_label("judge-server-2:8080") == "judge-server-2"`; URL form still works.

- [ ] **Step 1: Failing tests** — port each test in `test_sandbox_status.py` from `requests.post` pongs to a patched `sandbox_status._stub` (`Ping` returning a `PingResponse`); add `test_relay_includes_running_jobs`, `test_ping_rpc_error_marks_down_and_continues`; `test_sandbox_health.py`: `test_label_host_port`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement.** **Step 4: Run** `pytest -q` — PASS.
- [ ] **Step 5: Commit** — `feat(status): ping the sandboxes over gRPC and relay running_jobs in the heartbeat`

---

### Task 6: Worker README and config docs

**Files:**
- Modify: `judge-worker/README.md:4,14,17,28` (gRPC instead of `/judge`, `/ping`; address forms; `JUDGE_TIMEOUT_MAX_SECONDS`), `judge-worker/config.py` comments at `JUDGE_SERVER_URL`, `JUDGE_TIMEOUT_SECONDS`, `MAX_POLL_INTERVAL_MS` (recompute the worst-case stretch with the 300 s cap: MinIO 3×60 + 2×300 > 600 s is NOT allowed → set `MAX_POLL_INTERVAL_MS` default to 900000 and say why, or lower `JUDGE_TIMEOUT_MAX_SECONDS`; pick raising the poll interval, since a failover after a 300 s deadline is the rare case).

- [ ] **Step 1: Edit docs and comments**; `test_config.py`: `test_max_poll_interval_default_900s`.
- [ ] **Step 2: Run** `pytest -q` — PASS. **Step 3: Commit** — `docs(worker): describe the gRPC sandbox contract, address forms and the scaled deadline budget`

---

### Task 7: Compose cut-over and mock swap

**Files:**
- Modify: `judge-deployment/docker-compose.yml` (`x-sandbox-health` lines 57-65, `x-sandbox` 83-110, `x-sandbox-env` 112-114, services `judge-server`/`judge-server-2` 1098-1140, worker env 1038 and run-worker env 1089, the comment block at 66-82, `stop_grace_period` of the workers if below 330 s), `judge-deployment/docker-compose.mock.yml` (whole file), `judge-deployment/README.md` (lines 32, 51, 72, 124, 422-431, 559-561, 854-869; add a "Go sandbox" subsection with the rollback SQL for V11 and the compose revert), `judge-deployment/docs/superpowers/specs/2026-10-28-k3s-judge-pod-spec.md` row 5 and `plans/2026-10-28-k3s-migration.md:19,103-104` (sandbox limits 1.5Gi, probe becomes `judge-server healthcheck`, mock patch uses the Go image `mock`)
- Delete: `judge-deployment/mock-judge-server/` (Dockerfile, app.py, test_app.py)

**Interfaces:**
- `x-sandbox`: `image: ${OJ_REGISTRY:-docker.io/thanhtuanle}/judge-server:${OJ_SANDBOX_TAG:-${OJ_TAG:-main}}` with `build: ../judge-server` (the other services' pattern), `mem_limit: 1536m`, `cpus: 2`, tmpfs `/work:exec,mode=755,size=512m`, `/tmp:size=64m`; drop `shm_size` (unused) and the `/log` volumes (`js1log`, `js2log`); keep caps, `read_only`, `security_opt`, `pids_limit`, `java-policy` config, tls volume, `test_case_cache:/test_case:ro`.
- `x-sandbox-health`: `test: ["CMD", "/usr/local/bin/judge-server", "healthcheck"]`, same timings.
- `x-sandbox-env`: `TOKEN: ${JUDGE_SERVER_TOKEN}`, `TLS_DIR: /etc/oj/tls`, `JUDGE_ALLOWED_CLIENTS: judge-worker,run-worker`, `LOG_FORMAT: json`; remove `GUNICORN_CMD_ARGS`, `SERVICE_URL`.
- Workers: `JUDGE_SERVER_URL: judge-server:8080,judge-server-2:8080`.
- `docker-compose.mock.yml`: both sandboxes `command: ["mock"]` on the same image (TLS and auth inherited, so no URL change for the workers); healthcheck stays the real one (`healthcheck` works against `mock`). Delete the Python mock directory.

- [ ] **Step 1: Edit compose files and delete the mock directory.** `docker compose config -q` — Expected: no error.
- [ ] **Step 2: Build and start the mock stack** — `docker compose -f docker-compose.yml -f docker-compose.mock.yml up -d --build judge-server judge-server-2 judge-worker run-worker`; `docker compose ps` → both sandboxes `healthy`; worker logs show both marked up; submit a `TRIGGER_WA` source through the portal → verdict WRONG_ANSWER on case 2.
- [ ] **Step 3: Start the real stack** — `docker compose up -d --build`; submit the part-1 corpus (`judge-server/testdata/corpus`) for each language through the API; expected verdicts per `corpus.json`.
- [ ] **Step 4: Update README and the k3s spec/plan rows**; README gains: the new caps table (§6), the env table, the deadline formula, rollback (`git checkout -- docker-compose.yml`, previous worker tag, V11 rollback SQL), and the removal of the Python mock.
- [ ] **Step 5: Commit** — `git -C judge-deployment checkout -b feat/go-judge-server` then `feat(sandbox): run the Go judge-server over gRPC with 1.5 GiB caps and its mock subcommand`

---

### Task 8: Parity and memory verification (§9.3-9.4)

**Files:**
- Create: `judge-deployment/scripts/parity-run.sh` (submits every corpus file through the gateway as a test user, polls the verdict, prints `lang file expected got` and exits non-zero on a mismatch not listed in `parity-exceptions.txt`), `judge-deployment/scripts/parity-exceptions.txt` (`cpp/crlf.cpp WA->AC`, `cpp/stderr.cpp WA->AC`)
- Modify: `judge-deployment/README.md` (how to run it)

- [ ] **Step 1: Baseline on qduoj** — `git stash` the compose change or check out the previous commit of `docker-compose.yml` only; `docker compose up -d`; `scripts/parity-run.sh > /tmp/parity-qduoj.txt`.
- [ ] **Step 2: Go sandbox** — restore the compose change; `docker compose up -d --build`; `scripts/parity-run.sh > /tmp/parity-go.txt`; `diff` the two: only the exception lines differ.
- [ ] **Step 3: Memory** — during a run of the whole corpus with 8 parallel submissions: `docker stats --no-stream oj-judge-server oj-judge-server-2` sampled every 2 s into a file; max sum ≤ 3 GiB; `docker inspect -f '{{.State.OOMKilled}}'` both `false`.
- [ ] **Step 4: Record results** in the README's Go sandbox subsection (date, image digest, max memory observed, latency of the 20-case C++ problem before/after).
- [ ] **Step 5: Commit** — `test(sandbox): parity script against qduoj with the two intended divergences listed`

---

## Self-review notes

- Spec coverage: §7 migrations Tasks 1-2; §8 worker Tasks 3-6, mock/compose Task 7; §4.2 worker side Tasks 3-4; §9.3-9.4
  Task 8; §11.1 deadline Task 4; k3s docs Task 7.
- Type consistency: `response_to_dict`, `build_judge_request`, `parse_address` named identically in Tasks 3 and 5;
  `judge_deadline_seconds` in Task 4 only; `JUDGE_TIMEOUT_MAX_SECONDS` in Tasks 4 and 6.
- Review Focus items 1-5 have tests in Tasks 3, 4, 3, 4, 5.
- Ordering: part 1 complete and its image built before Task 7; Tasks 1-6 can run in parallel with part 1 once the proto
  (part 1 Task 1) exists.
