# Phase 1 Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sửa các lỗi chặn đường trước khi worker được scale trên K3s: worker chịu SIGTERM và poison pill, verdict mang tên pod, PENDING timeout không giết bài còn xếp hàng, outbox không kẹt, run lane chạy nhiều replica, Bean Validation thật sự chạy, Java/Go có seccomp, edge có security header, Kafka có cap memory.

**Architecture:** Mỗi task là một commit trên nhánh `main` của repo tương ứng (project cá nhân, không MR bắt buộc). Thứ tự giữa repo: worker (T1–T4) → submission-service (T5–T8) → validation (T9) → seccomp (T10) → edge/portal (T11) → compose Kafka (T12). T4 và T5 là một cặp (worker gửi `judgedBy`, service đọc): deploy worker trước vẫn an toàn vì T5 thêm `ignoreUnknown`... nhưng **T5 phải deploy trước T4** (xem T5 ghi chú).

**Tech Stack:** Python 3.11 / kafka-python 3.0.11 / pytest; Java 17 / Spring Boot 3.5 / Flyway / Testcontainers; Vue 3 / vitest; Caddy 2; Docker Compose.

**Spec:** `judge-deployment/docs/superpowers/specs/2026-10-28-k3s-judge-pod-spec.md`

## Global Constraints

- Commit message một dòng, `type(scope): ...`, không trailer, không attribution.
- Không Jira, không ticket, không ghi ngoài `~/Personal/my-oj`.
- Mọi test hiện có của repo phải vẫn pass: worker `pytest -q`, Java `./mvnw verify` (Testcontainers bắt buộc), portal `npm test`, deployment `bash tests/compose.test.sh`.
- Giá trị cố định: `terminationGracePeriodSeconds: 120` (K3s) ⇒ worker phải thoát trong 120 s sau SIGTERM; `MAX_POLL_INTERVAL_MS` default mới = 600000; Kafka heap `-Xmx512M -Xms512M`, `mem_limit: 1g`.
- Tên trường mới trong event `submission.judged` và `run.judged`: `judgedBy` (camelCase như `submissionId`, `rejudgeCount`); cột DB `t_submissions.judged_by VARCHAR(255) NULL`.
- Consumer group mới của run lane: `run-results-<RUN_INSTANCE_ID>`, `RUN_INSTANCE_ID` default = hostname.

## Review Focus

1. SIGTERM đến **giữa** `wait()` của infra-retry (Kafka/MinIO đang down): worker phải thoát ngay sau khi vòng wait hiện tại trả về, không chờ hết 300 s retry — test ở T2.
2. SIGTERM đến khi **không** có bài (đang block trong `for msg in consumer`): phải thoát trong ≤ `poll timeout` — test ở T2 (`consumer_timeout_ms`).
3. Event hợp lệ nhưng `expiresAt` là chuỗi `"abc"`: skip + commit, không crash — test ở T1.
4. PENDING cũ hơn 30 phút nhưng queue vẫn đang được rút (worker sống, lag giảm): không được SYSTEM_ERROR — test ở T6.
5. Outbox row không gửi được 5 lần liên tiếp: các row sau nó vẫn được gửi, row đó có `dead_at` — test ở T7.

---

### Task 1: judge-worker — poison pill và `expiresAt` sai kiểu không làm chết process

**Files:**
- Modify: `judge-worker/worker.py:143-147` (`is_expired`), `:178-202` (`run`)
- Modify: `judge-worker/handler.py:19-25` (`job_identity`)
- Modify: `judge-worker/metrics.py` (thêm counter)
- Test: `judge-worker/tests/test_worker.py`, `judge-worker/tests/test_handler.py`

**Interfaces:**
- Produces: `metrics.POISON_PILL = Counter("oj_poison_pill_total", "...", ["reason"])`; `job_identity(event)` trả `None` khi `event` không phải `dict`; `is_expired(event, now_ms)` trả `False` khi `expiresAt` không phải `int`/`float`.

- [ ] **Step 1: Viết test fail trong `tests/test_handler.py`**

```python
def test_job_identity_non_dict_returns_none():
    assert job_identity([]) is None
    assert job_identity(1) is None
    assert job_identity("x") is None
```

và trong `tests/test_worker.py`:

```python
def test_handle_one_skips_non_object_json(config, producer):
    handle_one([], config, producer)          # không raise
    producer.send.assert_not_called()

def test_is_expired_ignores_non_numeric_expires_at():
    assert is_expired({"runId": "r", "expiresAt": "abc"}, now_ms=10) is False

def test_run_commits_and_continues_after_poison_pill(config, producer):
    consumer = FakeConsumer([record(b"[]"), record(b'{"submissionId":"s1", ...}')])
    run(config, consumer, producer)
    assert consumer.commits == 2
    assert POISON_PILL.labels("non_object")._value.get() == 1
```

(`FakeConsumer`/`record` theo pattern có sẵn trong `test_worker.py`.)

- [ ] **Step 2: Chạy test, xác nhận fail**

Run: `cd judge-worker && pytest tests/test_handler.py tests/test_worker.py -k "poison or non_dict or non_numeric" -v`
Expected: FAIL (`AttributeError: 'list' object has no attribute 'get'`, `TypeError`)

- [ ] **Step 3: Sửa `job_identity`, `is_expired`, bọc `handle_one` trong `run`**

`job_identity`: `if not isinstance(event, dict): return None`. `is_expired`: `isinstance(expires_at, (int, float))`. Trong `run`: `try: handle_one(...) except Exception: log.exception("Poison pill at %s/%d", msg.topic, msg.offset); POISON_PILL.labels("exception").inc()` rồi vẫn `resume` + `commit`. Trong `handle_one`, nhánh `identity is None` khi `event` không phải dict → `POISON_PILL.labels("non_object").inc()`.

- [ ] **Step 4: Chạy toàn bộ test worker**

Run: `cd judge-worker && pytest -q`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C judge-worker add worker.py handler.py metrics.py tests/
git -C judge-worker commit -m "fix(worker): commit and count a poison-pill record instead of crash-looping on it"
```

---

### Task 2: judge-worker — graceful shutdown trên SIGTERM/SIGINT

**Files:**
- Create: `judge-worker/shutdown.py`
- Modify: `judge-worker/worker.py:178-202` (`run`), `judge-worker/main.py:21-37,48-` (`build_consumer`, `main`)
- Modify: `judge-worker/Dockerfile:17` (`CMD` → `ENTRYPOINT ["tini","--","python","main.py"]`, cài `tini` qua apt)
- Modify: `judge-deployment/docker-compose.yml` services `judge-worker`, `run-worker`: `stop_grace_period: 120s`
- Test: `judge-worker/tests/test_shutdown.py`, `judge-worker/tests/test_worker.py`

**Interfaces:**
- Produces: `shutdown.Shutdown` với `install(signals=(SIGTERM, SIGINT))`, property `requested: bool`, `request()`; `run(config, consumer, producer, shutdown: Shutdown)` — thoát vòng lặp sau khi commit bài hiện tại nếu `shutdown.requested`; `wait(seconds)` bên trong `run` trả về sớm khi `shutdown.requested` (poll theo lát 1 s).
- `build_consumer` đặt `consumer_timeout_ms=1000` để `for msg in consumer` nhả về mỗi giây khi không có record.

- [ ] **Step 1: Viết test fail `tests/test_shutdown.py` và bổ sung `tests/test_worker.py`**

```python
def test_request_sets_flag():
    s = Shutdown(); assert not s.requested; s.request(); assert s.requested

def test_install_handles_sigterm():
    s = Shutdown(); s.install(); os.kill(os.getpid(), signal.SIGTERM); assert s.requested
```

```python
def test_run_finishes_current_record_then_exits(config, producer):
    s = Shutdown()
    consumer = FakeConsumer([record_json(sub("s1")), record_json(sub("s2"))])
    producer.send.side_effect = lambda *a, **k: (s.request(), ok_future())[1]   # SIGTERM giữa bài 1
    run(config, consumer, producer, shutdown=s)
    assert consumer.commits == 1            # bài 1 commit, bài 2 không nhận
    assert consumer.closed

def test_wait_returns_early_when_shutdown_requested(config, producer):
    s = Shutdown(); s.request()
    t0 = time.monotonic(); run_wait(s, seconds=30); assert time.monotonic() - t0 < 2

def test_run_exits_when_idle_and_shutdown_requested(config, producer):
    s = Shutdown(); s.request()
    consumer = FakeConsumer([], timeout_ms=1000)
    run(config, consumer, producer, shutdown=s)   # trả về, không treo
```

- [ ] **Step 2: Chạy test, xác nhận fail**

Run: `cd judge-worker && pytest tests/test_shutdown.py tests/test_worker.py -k shutdown -v`
Expected: FAIL (`ModuleNotFoundError: shutdown`, `TypeError: run() got an unexpected keyword 'shutdown'`)

- [ ] **Step 3: Implement `shutdown.py`, sửa `run`, `wait`, `build_consumer`, `main`**

`Shutdown` dùng `threading.Event`. `run`: vòng `while not shutdown.requested: for msg in consumer: ... ; if shutdown.requested: break` và `consumer.close()` ở cuối (close commit nothing; đã commit trước đó). `wait(seconds)`: lặp `poll(timeout_ms=1000)` tối đa `seconds` lần, dừng sớm khi `shutdown.requested`. `main()` tạo `Shutdown().install()` và truyền vào `run`; sau `run` trả về, `sys.exit(0)`.

- [ ] **Step 4: Dockerfile và compose**

Dockerfile: `apt-get install -y --no-install-recommends tzdata tini`, `ENTRYPOINT ["/usr/bin/tini", "--"]`, `CMD ["python", "main.py"]`. Compose: `stop_grace_period: 120s` cho `judge-worker` và `run-worker`; thêm vào allowlist của `judge-deployment/tests/compose.test.sh` nếu test đó liệt kê key.

- [ ] **Step 5: Chạy test worker + compose test**

Run: `cd judge-worker && pytest -q && cd ../judge-deployment && bash tests/compose.test.sh`
Expected: PASS

- [ ] **Step 6: Kiểm tra live trên compose**

Run: build worker, `docker compose up -d --no-build judge-worker`, submit một bài C++ chạy ~10 s, rồi `docker compose stop judge-worker` ngay lập tức.
Expected: log worker `shutdown requested; finishing <id>` → verdict thật trong DB, `docker compose ps` exit code 0, thời gian stop < 120 s; không có SYSTEM_ERROR.

- [ ] **Step 7: Commit (2 repo)**

```bash
git -C judge-worker add shutdown.py worker.py main.py Dockerfile tests/
git -C judge-worker commit -m "feat(worker): finish the current judgement and exit cleanly on SIGTERM (tini as PID 1)"
git -C judge-deployment add docker-compose.yml tests/compose.test.sh
git -C judge-deployment commit -m "feat(compose): give the workers a 120 s stop grace period for graceful shutdown"
```

---

### Task 3: judge-worker — poll budget bao MinIO sync và failover; `resolve_verdict` đối chiếu số case

**Files:**
- Modify: `judge-worker/config.py:63-66` (`MAX_POLL_INTERVAL_MS` default), `judge-worker/tls.py:64-68` (MinIO timeouts), `judge-worker/worker.py:116-141` (`judge_with_infra_retry`), `judge-worker/verdict.py:13-29`, `judge-worker/handler.py:28-52` (`build_judged_event`)
- Test: `judge-worker/tests/test_config.py`, `tests/test_verdict.py`, `tests/test_handler.py`, `tests/test_worker.py`

**Interfaces:**
- `Config.MAX_POLL_INTERVAL_MS` default `600000`; `Config.MINIO_TIMEOUT_SECONDS` default `60` (connect+read), `Retry(total=2)`.
- `resolve_verdict(details, expected_count: int | None = None)`: `expected_count` khác `None` và `len(details) != expected_count` → `SYSTEM_ERROR`; `details == []` và `expected_count is None` → `SYSTEM_ERROR` (không còn ACCEPTED).
- `build_judged_event(submission_id, judge_response, id_key, expected_count=None)` truyền `expected_count` xuống; `process_event` lấy `expected_count` từ `info` của bundle (`test_case_number`) khi là submission, từ `len(event["cases"])` khi là run.

- [ ] **Step 1: Test fail**

```python
# test_config.py
def test_max_poll_interval_default_is_ten_minutes(monkeypatch): ... == 600000
# test_verdict.py
def test_empty_details_is_system_error(): assert resolve_verdict([]) == SYSTEM_ERROR
def test_fewer_cases_than_expected_is_system_error(): assert resolve_verdict([ok()], expected_count=2) == SYSTEM_ERROR
def test_all_cases_present_and_passing_is_accepted(): assert resolve_verdict([ok(), ok()], expected_count=2) == ACCEPTED
# test_worker.py
def test_minio_sync_failure_is_retried_inside_infra_budget(...)  # ensure_present raise → wait() được gọi, poll giữ group
```

- [ ] **Step 2: Chạy, xác nhận fail**

Run: `cd judge-worker && pytest tests/test_config.py tests/test_verdict.py tests/test_worker.py -k "poll_interval or empty_details or fewer_cases or minio_sync" -v`
Expected: FAIL

- [ ] **Step 3: Implement**

`config.py`: `MAX_POLL_INTERVAL_MS = _int_env("MAX_POLL_INTERVAL_MS", 600000)`; `MINIO_TIMEOUT_SECONDS = _int_env("MINIO_TIMEOUT_SECONDS", 60)`. `tls.py` dùng giá trị đó cho urllib3 `Timeout(connect=, read=)`, `Retry(total=2)`. `judge_with_infra_retry`: `ensure_present` đã nằm trong `process_event` → xác nhận exception của nó được `infra_errors` phân loại là retryable (nếu chưa: thêm `urllib3.exceptions.HTTPError`, `minio.error.S3Error` 5xx vào `infra_errors.py`). `verdict.py`, `handler.py` theo Interfaces.

- [ ] **Step 4: Test toàn bộ**

Run: `cd judge-worker && pytest -q`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -C judge-worker add config.py tls.py worker.py verdict.py handler.py infra_errors.py tests/
git -C judge-worker commit -m "fix(worker): 10 min poll budget that covers MinIO sync; a short or empty result set is SYSTEM_ERROR"
```

---

### Task 4: judge-worker — `judgedBy` trong verdict và log; registry key theo pod

**Files:**
- Modify: `judge-worker/config.py:37` (`WORKER_ID` đọc `POD_NAME` trước `hostname`), `judge-worker/handler.py:54-70` (`_event`, `system_error_event`), `judge-worker/log_context.py`, `judge-worker/sandbox_status.py:33-47`
- Test: `tests/test_handler.py`, `tests/test_config.py`, `tests/test_sandbox_status.py`, `tests/test_log_context.py`

**Interfaces:**
- `Config.WORKER_ID = os.getenv("POD_NAME") or os.getenv("WORKER_ID") or socket.gethostname()`.
- Mọi event `submission.judged`/`run.judged` (kể cả `system_error_event`) có `"judgedBy": config.WORKER_ID`.
- Log format có `worker=<WORKER_ID>` sau `[<submission id>]`.
- `sandbox_status` **không đổi** (ruling T4): hostname gửi lên registry vẫn là hostname của sandbox. Compose giữ `judge-server`/`judge-server-2` cố định; trên K3s sandbox chung hostname với Pod nên tự thành tên pod. Nối `WORKER_ID` vào sẽ tạo một row Offline mới mỗi lần worker compose được tạo lại (README: "one per old container id").

**Phụ thuộc deploy:** Task 5 (service `ignoreUnknown`) **phải chạy trước** task này trên môi trường thật; nếu không `SubmissionJudgedEvent` fail parse → DLQ.

- [ ] **Step 1: Test fail** — `test_judged_event_carries_judged_by`, `test_system_error_event_carries_judged_by`, `test_worker_id_prefers_pod_name`, `test_relay_hostname_is_worker_slash_sandbox`.
- [ ] **Step 2: Run, FAIL.** `pytest tests/test_handler.py tests/test_config.py tests/test_sandbox_status.py -k judged_by -v`
- [ ] **Step 3: Implement** theo Interfaces; `_event` và `system_error_event` nhận `judged_by` từ `Config.WORKER_ID` (import trong handler, giữ chữ ký hiện tại và thêm tham số keyword `judged_by=None` → default `Config.WORKER_ID`).
- [ ] **Step 4: `pytest -q` PASS.**
- [ ] **Step 5: Commit** — `feat(worker): every verdict and heartbeat names the worker (POD_NAME) that judged it`

---

### Task 5: oj-submission-service — `judged_by` lưu và hiển thị; event bỏ qua field lạ

**Files:**
- Create: `oj-submission-service/src/main/resources/db/migration/V6__judged_by.sql`
- Modify: `messaging/event/SubmissionJudgedEvent.java` (thêm `@JsonIgnoreProperties(ignoreUnknown = true)` + `private String judgedBy;`), `messaging/event/RunJudgedEvent.java` (+`judgedBy`), `entity/Submission.java` (+`judgedBy`), `submission/SubmissionRepository.java:100-125` (các UPDATE verdict set `judged_by = :judgedBy`), `messaging/JudgeResultConsumer.java:64-74`, DTO admin detail (`submission/dto/...AdminSubmissionDetail...` — tìm bằng `grep -rn "rejudgeCount" src/main/java/vn/thanhtuanle/submission/dto`), `judgeserver/dto/JudgeServerHeartbeatDto.java` (hostname tới 255 ký tự)
- Test: `JudgeResultConsumerPostgresTest`, `SubmissionJudgedEventTest` (mới), `RunResultConsumerTest`

**Interfaces:**
- SQL: `ALTER TABLE t_submissions ADD COLUMN judged_by VARCHAR(255);`
- `SubmissionJudgedEvent.getJudgedBy(): String` (null từ worker cũ).
- `SubmissionRepository.applyVerdict(... , String judgedBy)` — hai câu UPDATE có guard `status IN (6,7)` set thêm `judged_by = :judgedBy`.
- Admin detail DTO: trường `judgedBy` (chỉ admin; user thường không thấy).

- [ ] **Step 1: Test fail**

```java
@Test void unknownFieldsInJudgedEventAreIgnored() { objectMapper.readValue("{\"submissionId\":\"..\",\"status\":4,\"foo\":1}", SubmissionJudgedEvent.class); }
@Test void judgedByIsStoredWithTheVerdict() { /* Postgres: consume event với judgedBy="judge-abc" → row.judged_by == "judge-abc" */ }
@Test void nullJudgedByFromAnOldWorkerIsAccepted() { ... row.judged_by == null, verdict vẫn ghi }
```

- [ ] **Step 2: `./mvnw -q test -Dtest='SubmissionJudgedEventTest,JudgeResultConsumerPostgresTest'` → FAIL.**
- [ ] **Step 3: Implement** V6, entity, event, repository, consumer, DTO.
- [ ] **Step 4: `./mvnw verify` → PASS.**
- [ ] **Step 5: Commit** — `feat(submission): store judged_by from the verdict event; ignore unknown event fields`

---

### Task 6: oj-submission-service — PENDING timeout không giết bài còn xếp hàng

**Files:**
- Modify: `submission/SubmissionTimeouts.java:62-71`, `submission/SubmissionReconcileJob.java`, `src/main/resources/application.yml:109-120`
- Test: `SubmissionTimeoutsTest`, `SubmissionReconcileJobTest`

**Interfaces:**
- Quy tắc mới: một PENDING chỉ bị SYSTEM_ERROR `Judging request lost` khi **cả hai**: `created_at < now - judge.pending-timeout` **và** không có submission nào chuyển sang JUDGING (`judging_started_at`) trong `judge.pending-progress-window` (default `5m`). Nghĩa là: queue đang được rút → không giết.
- `SubmissionTimeouts.failPendingCreatedBefore(threshold, now, LocalDateTime progressSince)`: thêm `AND NOT EXISTS (SELECT 1 FROM t_submissions WHERE judging_started_at >= :progressSince)`.
- `application.yml`: `judge.pending-timeout: ${JUDGE_PENDING_TIMEOUT:30m}`, `judge.pending-progress-window: ${JUDGE_PENDING_PROGRESS_WINDOW:5m}`.

- [ ] **Step 1: Test fail (Postgres)**

```java
@Test void aPendingOlderThanTimeoutIsKeptWhileTheQueueIsMoving()   // có row judging_started_at = now-1m → 0 rows updated
@Test void aPendingOlderThanTimeoutFailsWhenNothingStartedForFiveMinutes()
```

- [ ] **Step 2: FAIL.** `./mvnw -q test -Dtest=SubmissionTimeoutsTest`
- [ ] **Step 3: Implement** SQL + job + yml; cập nhật comment ở `application.yml:112-116` và README deployment bảng "Overload and verdict-correctness knobs" (dòng `JUDGE_PENDING_TIMEOUT`) mô tả quy tắc mới.
- [ ] **Step 4: `./mvnw verify` PASS.**
- [ ] **Step 5: Commit** — `fix(submission): a queued PENDING is not failed while judging is still progressing`

---

### Task 7: oj-submission-service — outbox: row chết không chặn hàng, gửi ngoài transaction

**Files:**
- Create: `db/migration/V7__outbox_attempts.sql`
- Modify: `messaging/outbox/OutboxMessage.java`, `OutboxRepository.java:18-20`, `OutboxRelay.java:60-110`
- Modify: `judge-deployment/alerts.yml` (alert `OutboxDeadRow`), `judge-deployment/README.md` mục outbox
- Test: `OutboxRelayPostgresTest`

**Interfaces:**
- SQL: `ALTER TABLE t_outbox ADD COLUMN attempts INT NOT NULL DEFAULT 0, ADD COLUMN dead_at TIMESTAMP NULL; CREATE INDEX ix_outbox_unpublished ON t_outbox (created_at) WHERE published_at IS NULL AND dead_at IS NULL;`
- `OutboxRelay.relayBatch()`: (1) transaction ngắn: `lockOldestUnpublished` (thêm `AND dead_at IS NULL`) → copy ra list → commit; (2) ngoài transaction: với mỗi row `sender.send`; thành công → `markPublished(id)`; lỗi → `markAttempt(id)` (`attempts+1`, `dead_at = now()` khi `attempts+1 >= props.maxAttempts` default 5) và **continue**, không `break`.
- Metric `oj_outbox_dead_total`; alert `OutboxDeadRow`: `increase(oj_outbox_dead_total[10m]) > 0` severity warning.
- Hai instance không gửi trùng: giữ `SKIP LOCKED` + thêm cột `claimed_until` (now + 30 s) đặt trong bước (1); bước (1) chỉ chọn `claimed_until IS NULL OR claimed_until < now()`.

- [ ] **Step 1: Test fail (Postgres, có sẵn harness `OutboxRelayPostgresTest`)**

```java
@Test void aRowThatFailsFiveTimesIsDeadAndLaterRowsStillGo()
@Test void noDatabaseTransactionIsOpenWhileSending()   // sender stub kiểm tra TransactionSynchronizationManager.isActualTransactionActive() == false
@Test void twoRelaysNeverSendTheSameRow()              // đã có, phải còn pass với claimed_until
```

- [ ] **Step 2: FAIL.**
- [ ] **Step 3: Implement** theo Interfaces.
- [ ] **Step 4: `./mvnw verify` PASS; `bash judge-deployment/tests/prometheus.test.sh` PASS (alert rule hợp lệ).**
- [ ] **Step 5: Commit (2 repo)** — `fix(submission): outbox sends outside the transaction and dead-letters a row after 5 failures`; `feat(alerts): OutboxDeadRow`

---

### Task 8: oj-submission-service — run lane: consumer group per instance

**Files:**
- Modify: `messaging/KafkaTopics.java:17`, `messaging/RunResultConsumer.java:20-35`, `run/RunService.java` (nơi publish `run.requested`), `src/main/resources/application.yml`
- Modify: `judge-deployment/kafka/acls.sh` (group pattern `run-results-` PREFIXED cho CN `submission-service`)
- Test: `RunEndpointKafkaTest`, `RunResultConsumerTest`, `judge-deployment/tests/kafka-acls.test.sh`

**Interfaces:**
- `run.instance-id: ${RUN_INSTANCE_ID:${HOSTNAME:local}}`; group = `"run-results-" + instanceId` qua `@KafkaListener(groupId = "#{@runProperties.instanceGroup}")`.
- Event `run.requested` mang `replyTo: <instanceId>`; worker echo nguyên (`run.judged` mang `replyTo`). `RunResultConsumer` bỏ qua event có `replyTo != instanceId` (mỗi instance đọc toàn topic, chỉ xử lý của mình).
- judge-worker: `build_judged_event` copy `replyTo` nếu có trong event vào — làm trong task này ở repo worker (sửa `handler.py` + test `test_handler.py::test_run_reply_echoes_reply_to`).

- [ ] **Step 1: Test fail** — `RunResultConsumerTest.ignoresRepliesForAnotherInstance`, `RunEndpointKafkaTest.replyToNamesThisInstance`, worker `test_run_reply_echoes_reply_to`.
- [ ] **Step 2: FAIL.**
- [ ] **Step 3: Implement** service + worker + `acls.sh` (`--group run-results- --resource-pattern-type prefixed`).
- [ ] **Step 4: `./mvnw verify`, `pytest -q`, `bash tests/kafka-acls.test.sh` PASS.**
- [ ] **Step 5: Live:** `docker compose up -d --scale submission-service=2` không khả thi vì `container_name`; kiểm tra thay bằng test Kafka Testcontainers với 2 context (`RunTwoInstancesKafkaTest`).
- [ ] **Step 6: Commit (3 repo)** — `feat(submission): run replies go to the instance that asked (group per instance)`; `feat(worker): echo replyTo on run.judged`; `feat(kafka): prefixed ACL for run-results- groups`

---

### Task 9: Bean Validation thật sự chạy (identity, problem, submission)

**Files:**
- Modify: `oj-identity-service/pom.xml`, `oj-problem-service/pom.xml`, `oj-submission-service/pom.xml` (thêm `spring-boot-starter-validation`), `oj-common/pom.xml:94` (sửa comment), `oj-identity-service/.../role/dto/CreateRoleRequest.java:7-8` (xóa comment "no-ops", thêm `@NotBlank @Size(max=64)` cho `name`)
- Modify: `oj-identity-service/.../user/UserController.java:75-103`, `security/SecurityController.java:50` (thêm `@Valid`)
- Modify: `oj-submission-service/.../judge/dto/SubmissionRequestDto.java:12-16` (`@NotBlank @Size(max = 10240) sourceCode`, `@NotBlank language`)
- Test (mới): `identity: LoginRequestValidationTest`, `problem: CreateProblemValidationTest`, `submission: SubmissionRequestValidationTest` — `@WebMvcTest` hoặc `MockMvc` qua `@SpringBootTest`

**Interfaces:** request sai → HTTP 400 với body lỗi chuẩn của `OjExceptionHandler` (`Validation failed: ...` đã có handler cho `MethodArgumentNotValidException` — xác nhận bằng `grep -n MethodArgumentNotValid oj-common/src/main/java`).

- [ ] **Step 1: Test fail** — `loginWithA65CharUsernameIs400`, `slugWithSlashIs400`, `nonPositiveTimeLimitIs400`, `sourceCodeOver10240CharsIs400`, `blankLanguageIs400`.
- [ ] **Step 2: FAIL (hiện trả 200/201/500).**
- [ ] **Step 3: Thêm starter, `@Valid`, constraint.** Kiểm tra lại mọi DTO có annotation `jakarta.validation` trong 3 repo (`grep -rln "jakarta.validation" src/main/java`) để chắc không có constraint cũ giờ bật lên mà sai (ví dụ `@Size` quá chặt cho dữ liệu hiện có): liệt kê trong commit message nếu phải nới.
- [ ] **Step 4: `./mvnw verify` cả 3 repo PASS.**
- [ ] **Step 5: Commit (4 repo)** — `fix(validation): add the Bean Validation provider so DTO constraints are enforced` (identity/problem/submission); `docs(pom): the validation starter is each service's own, not transitive` (oj-common)

---

### Task 10: Java/Go seccomp trong sandbox

**Files:**
- Create: `oj-submission-service/src/main/resources/db/migration/V8__java_go_seccomp.sql`
- Modify: `judge-deployment/README.md` (mục languages / sandbox)
- Test: thủ công trên compose (image thật), ghi kết quả vào README

- [ ] **Step 1: Thử nghiệm** — trên compose, `UPDATE t_languages SET seccomp_rule='general' WHERE identifier IN ('java','go')` tạm bằng `docker exec psql`, submit a+b Java và Go, rồi một bài fork (`Runtime.exec("ls")` / `os/exec`).
Expected: a+b → ACCEPTED; fork → RUNTIME_ERROR. Nếu a+b Java fail (JVM cần `clone`/`execve` ngoài profile `general`) → ghi lại lỗi.
- [ ] **Step 2: Viết V8** theo kết quả: `seccomp_rule='general'` cho ngôn ngữ chạy được; `is_disabled=true` cho ngôn ngữ không chạy được (quyết định C). Rollback DB thủ công của Step 1 trước khi chạy Flyway.
- [ ] **Step 3: `./mvnw verify` PASS; README:** bảng ngôn ngữ + seccomp + ngày kiểm tra, cùng kiểu với comment ở `V3`.
- [ ] **Step 4: Commit** — `fix(languages): Java and Go run under the general seccomp filter (or are disabled when the JVM cannot)`

---

### Task 11: Edge security headers + body limit; portal DOMPurify allow-list

**Files:**
- Modify: `judge-deployment/edge/Caddyfile`, `judge-deployment/tests/tls.test.sh` (hoặc test mới `tests/edge-headers.test.sh`)
- Modify: `judge-portal/src/lib/sanitize.ts:14`, `judge-portal/src/lib/math.ts:96-101`, `judge-portal/index.html:13-22` (theme script → external file `public/theme-init.js` để CSP không cần `unsafe-inline`)
- Test: `judge-portal/src/lib/__tests__/sanitize.spec.ts`

**Interfaces:**
- Caddy `header` block: `Content-Security-Policy "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' https: data:; font-src 'self' data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"`, `X-Content-Type-Options nosniff`, `Referrer-Policy strict-origin-when-cross-origin`, `X-Frame-Options DENY`; `request_body { max_size 1MB }` trong `handle /api/*`.
  (`style-src 'unsafe-inline'` vì Monaco/KaTeX inject style; `img-src https:` vì avatar Google. Nếu portal còn inline script nào khác sau khi tách theme script, test build sẽ báo qua console CSP — kiểm tra bằng Step 5.)
- `sanitizeHtml`: `DOMPurify.sanitize(dirty, { ALLOWED_TAGS: [p, br, strong, em, u, s, code, pre, h1..h4, ul, ol, li, blockquote, a, img, table, thead, tbody, tr, th, td, sup, sub, span], ALLOWED_ATTR: [href, src, alt, title, class, colspan, rowspan, target, rel], FORBID_TAGS: [style, form, input, button, textarea, select, iframe], FORBID_ATTR: [style, id, name] })`; `math.ts` pass hai giữ profile SVG + MathML nhưng thêm cùng `FORBID_TAGS`.

- [ ] **Step 1: Test fail `sanitize.spec.ts`**

```ts
it('drops style, form and inputs', () => {
  const out = sanitizeHtml('<style>body{display:none}</style><form action="https://x"><input name=p></form><p>ok</p>')
  expect(out).toBe('<p>ok</p>')
})
it('drops inline style and id', () => expect(sanitizeHtml('<p style="x" id="y">a</p>')).toBe('<p>a</p>'))
it('keeps the tiptap set', () => expect(sanitizeHtml('<h2>t</h2><ul><li><code>x</code></li></ul>')).toContain('<h2>t</h2>'))
```

- [ ] **Step 2: `npm test -- sanitize` FAIL.**
- [ ] **Step 3: Implement** `sanitize.ts`, `math.ts`, Caddyfile, tách theme script.
- [ ] **Step 4: `npm test`, `npm run build`, `bash judge-deployment/tests/compose.test.sh` PASS.** Thêm vào `tls.test.sh` (hoặc file mới) kiểm tra `curl -sI https://localhost/ | grep -i content-security-policy` và `curl -X POST --data-binary @2MB https://localhost/api/v1/submissions` → 413.
- [ ] **Step 5: Live:** mở portal, DevTools console không có lỗi CSP trên trang problem (statement có công thức + ảnh), submit, admin pages.
- [ ] **Step 6: Commit (2 repo)** — `feat(edge): CSP, nosniff, referrer and frame headers; 1 MB API body limit`; `fix(portal): statement sanitiser allows only the tiptap tag set`

---

### Task 12: Compose — Kafka heap và memory cap

**Files:**
- Modify: `judge-deployment/docker-compose.yml` service `kafka` (`KAFKA_HEAP_OPTS: "-Xmx512M -Xms512M"`, `mem_limit: 1g`), `kafka-init` (`mem_limit: 512m`)
- Modify: `judge-deployment/README.md` bảng Services (dòng kafka)
- Test: `tests/compose.test.sh`

- [ ] **Step 1: Sửa compose + README.**
- [ ] **Step 2: `bash tests/compose.test.sh` PASS; `docker compose up -d kafka` → healthy; `docker stats oj-kafka` RSS < 1 GiB sau 10 phút với bench nhẹ (`bench/` k6 smoke).**
- [ ] **Step 3: Commit** — `feat(compose): cap Kafka at 512M heap and 1g memory`

---

## Self-review

- Spec coverage: §4 mục 1 → T1–T4; mục 2 → T5–T8; mục 3 → T9; mục 4 → T10; mục 5 → T11; mục 6 → T12. Yêu cầu gốc "max_poll_interval 600000" → T3; "SIGTERM" → T2; "judged_by" → T4+T5. ✔
- Tên nhất quán: `judgedBy` (event), `judged_by` (SQL), `Config.WORKER_ID`, `Shutdown`, `POISON_PILL`, `replyTo`, `RUN_INSTANCE_ID`. ✔
- Review Focus 1–2 → T2; 3 → T1; 4 → T6; 5 → T7. ✔
- Rủi ro còn mở: T10 phụ thuộc hành vi JVM dưới seccomp `general` — kết quả quyết định nội dung V8, đã chừa hai nhánh.
